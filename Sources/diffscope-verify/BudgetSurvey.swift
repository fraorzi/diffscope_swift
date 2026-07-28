import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// Measures what the budgets in `16-performance-and-scaling.md` §3 are supposed to be derived from.
/// Node count and matching time are the two numbers that document marks as estimates, and they are
/// the two carrying the risk it names: matching is superlinear in node count, and a minified file
/// has a wildly different node count from a hand-written file of the same size.
///
/// Read-only: it parses and matches, and writes nothing.
func runBudgetSurvey(root: URL, limit: Int = 400) {
    guard let parser = TSXParser() else {
        print("parser unavailable")
        return
    }
    let fm = FileManager.default
    var rows: [(path: String, bytes: Int, nodes: Int, parseMs: Double, matchMs: Double,
                longestLine: Int, work: Double)] = []

    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
    for case let url as URL in walker {
        if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
            walker.skipDescendants(); continue
        }
        guard ["tsx", "ts", "jsx", "js"].contains(url.pathExtension) else { continue }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
        let bytes = [UInt8](data)
        guard classify(path: url.lastPathComponent, bytes: bytes).isStructural else { continue }

        let parseStarted = Date()
        guard let tree = parser.parseTree(bytes) else { continue }
        let parseMs = Date().timeIntervalSince(parseStarted) * 1000

        // The same perturbation the other corpus measurements use, so the numbers are comparable:
        // a rename-shaped edit, which is the case that keeps the matcher busiest.
        guard let text = String(bytes: bytes, encoding: .utf8) else { continue }
        let perturbed = text.replacingOccurrences(of: "className", with: "class_Name")
            .replacingOccurrences(of: "const ", with: "let ")
        guard perturbed != text, let perturbedTree = parser.parseTree([UInt8](perturbed.utf8)) else { continue }

        let matchStarted = Date()
        let mapping = matchTrees(old: tree, new: perturbedTree,
                                 settings: MatcherSettings(matchWorkBudget: .max))
        let matchMs = Date().timeIntervalSince(matchStarted) * 1000

        var longestLine = 0
        var current = 0
        for byte in bytes {
            if byte == 0x0A { longestLine = max(longestLine, current); current = 0 } else { current += 1 }
        }
        longestLine = max(longestLine, current)

        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        rows.append((relative, bytes.count, tree.nodes.count, parseMs, matchMs,
                     longestLine, Double(mapping.workUsed)))
        if rows.count >= limit { break }
    }

    guard !rows.isEmpty else { print("no structural files found under \(root.path)"); return }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }

    let nodes = rows.map { Double($0.nodes) }
    let matchMs = rows.map(\.matchMs)
    let nodesPerKB = rows.map { Double($0.nodes) / (Double($0.bytes) / 1024) }
    let lines = rows.map { Double($0.longestLine) }

    print("surveyed \(rows.count) structural files under \(root.path)\n")
    print(String(format: "  %-16@  %10@ %10@ %10@ %10@", "" as NSString,
                 "p50" as NSString, "p95" as NSString, "p99" as NSString, "max" as NSString))
    func row(_ name: String, _ values: [Double], _ format: String = "%10.0f") {
        print(String(format: "  %-16@" + format + format + format + format, name as NSString,
                     percentile(values, 0.5), percentile(values, 0.95),
                     percentile(values, 0.99), values.max() ?? 0))
    }
    row("nodes", nodes)
    row("nodes per KB", nodesPerKB, "%10.1f")
    row("match ms", matchMs, "%10.2f")
    row("longest line", lines)

    print("\n  the ten costliest files to match:")
    for entry in rows.sorted(by: { $0.matchMs > $1.matchMs }).prefix(10) {
        print(String(format: "    %-44@ %7d B  %6d nodes  parse %6.1f ms  match %8.2f ms",
                     entry.path as NSString, entry.bytes, entry.nodes, entry.parseMs, entry.matchMs))
    }

    // The pathological case the corpus does not contain. `16-…` §2 records difftastic #373 — a
    // moderate-size lockfile consuming 64 GB — as the precedent, so the shape worth measuring is a
    // dense machine-generated file rather than a large hand-written one.
    print("\n  synthetic pathological inputs:")
    // Budgets are removed for the survey itself: the point is to see the curve, and a gate would
    // hide exactly the part of it the gate is being chosen from.
    let unlimited = MatcherSettings(matchWorkBudget: .max)
    for (name, sources) in [("dense JSX", [200, 400, 800, 1600].map(syntheticDenseJSX)),
                            ("minified", [400, 800, 1600, 3200].map(syntheticMinified))] {
        for source in sources {
            let bytes = [UInt8](source.utf8)
            guard let tree = parser.parseTree(bytes) else { continue }
            let perturbed = [UInt8](source.replacingOccurrences(of: "item", with: "entry")
                .replacingOccurrences(of: "const a", with: "const b").utf8)
            guard let perturbedTree = parser.parseTree(perturbed) else { continue }
            let started = Date()
            let mapping = matchTrees(old: tree, new: perturbedTree, settings: unlimited)
            let ms = Date().timeIntervalSince(started) * 1000
            print(String(format: "    %-10@ %8d B  %7d nodes  match %9.1f ms  work %12d",
                         name as NSString, bytes.count, tree.nodes.count, ms, mapping.workUsed))
        }
    }

    let work = rows.map { Double($0.work) }
    print("\n  work units on the real corpus:")
    row("match work", work)
    if let costliest = rows.max(by: { $0.work < $1.work }) {
        print(String(format: "    costliest: %@ — %d nodes, %d work, %.0f ms",
                     costliest.path, costliest.nodes, Int(costliest.work), costliest.matchMs))
    }

    // What the gates actually reject, on this corpus. A budget that rejects a large share of real
    // source code is not a budget, and this is the number that says which it is.
    let oversize = rows.filter { $0.bytes > structuralSizeLimit }
    let dense = rows.filter { $0.bytes <= structuralSizeLimit && $0.nodes > structuralNodeBudget }
    let expensive = rows.filter {
        $0.bytes <= structuralSizeLimit && $0.nodes <= structuralNodeBudget && Int($0.work) > matchWorkBudget
    }
    print(String(format: "\n  gates on %d files: size %d, nodes %d, work %d — structural %d (%.1f%%)",
                 rows.count, oversize.count, dense.count, expensive.count,
                 rows.count - oversize.count - dense.count - expensive.count,
                 Double(rows.count - oversize.count - dense.count - expensive.count) / Double(rows.count) * 100))
    // The ones nearest the gate are the interesting ones: if any of them is hand-written source
    // rather than build output, the budget is in the wrong place.
    for entry in (dense + expensive).sorted(by: { $0.nodes < $1.nodes }).prefix(8) {
        print(String(format: "    nearest the gate: %-70@ %8d B %7d nodes",
                     entry.path as NSString, entry.bytes, entry.nodes))
    }
}

/// Dense nested JSX — the shape `16-…` §7 names as the matcher's worst case, because every element
/// contributes several nodes and the structural hashes repeat.
func syntheticDenseJSX(elements: Int) -> String {
    let items = (0..<elements).map { index in
        "      <li className=\"item\" key={\(index)}><span>{item\(index).label}</span></li>\n"
    }.joined()
    return """
    export function List({ items }) {
      return (
        <ul className="list">
    \(items)    </ul>
      );
    }

    """
}

/// One very long line of many small statements: the same byte count as the JSX above, but a
/// completely different node count, which is the reason the budget is on nodes and not on bytes.
func syntheticMinified(statements: Int) -> String {
    (0..<statements).map { "const a\($0)=\($0)+a\(max(0, $0 - 1));" }.joined() + "\n"
}
