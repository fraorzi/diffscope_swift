import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runMoveChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    guard let parser = TSXParser() else { report("parser for the move checks", false); return }

    func diff(_ old: String, _ new: String, floor: Int = moveContentFloor) -> StructuralResult {
        structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                       newPath: "a.tsx", newBytes: [UInt8](new.utf8), parser: parser,
                       settings: MatcherSettings(moveContentFloor: floor))
    }

    /// The DEC-038 pass condition, asked of the model rather than of the search: content the
    /// model calls moved must be byte-equal across the two sides, linked pair by linked pair.
    func movedContentAgrees(_ result: StructuralResult) -> Bool {
        func byLink(_ partition: Partition, _ bytes: [UInt8]) -> [Int: [UInt8]] {
            var out: [Int: [UInt8]] = [:]
            for segment in partition.segments where segment.label == .moved {
                guard let link = segment.link else { continue }
                out[link, default: []] += bytes[segment.start..<segment.end]
            }
            return out
        }
        let old = byLink(result.model.oldPartition, result.model.oldBytes)
        let new = byLink(result.model.newPartition, result.model.newBytes)
        guard !old.isEmpty else { return true }
        return old.allSatisfy { link, content in new[link] == content }
    }

    print("\n=== DEC-038: byte-identical moves, found deliberately ===")
    do {
        let before = """
        const helper = (value: string) => value.trim().toLowerCase();

        export function Page() {
          return <main>{helper("x")}</main>;
        }

        """
        let after = """
        export function Page() {
          return <main>{helper("x")}</main>;
        }

        const helper = (value: string) => value.trim().toLowerCase();

        """
        let result = diff(before, after)
        report("a relocated declaration is found as a move", result.stats.movesFound > 0,
               "\(result.stats.movesFound) moves")
        report("the moved content is byte-identical on both sides", movedContentAgrees(result))
        report("the move satisfies the invariants", validate(result.model).passed,
               validate(result.model).summary)
        report("and nothing is reported as unchanged that was not", !result.model.presentsNoChanges)

        let again = diff(before, after)
        report("the search is deterministic",
               result.model.oldPartition == again.model.oldPartition
                   && result.model.newPartition == again.model.newPartition)

        print("        moved-and-modified stays delete-plus-add, as DEC-038 accepts")
        let modified = diff(before, after.replacingOccurrences(of: "toLowerCase", with: "toUpperCase"))
        report("a move with an edit inside it is not claimed as a move",
               modified.stats.movesFound == 0, "\(modified.stats.movesFound) moves")
        report("and the edited version still satisfies the invariants", validate(modified.model).passed)

        print("        the floor is disclosed, not silent — the git --color-moved complaint")
        let short = "const x = 1;\n\nfunction f() {\n  return 2;\n}\n"
        let shortMoved = "function f() {\n  return 2;\n}\n\nconst x = 1;\n"
        let tiny = diff(short, shortMoved)
        report("a move below the content floor is counted rather than dropped",
               tiny.stats.movesFound == 0 && tiny.stats.movesBelowFloor > 0,
               "found \(tiny.stats.movesFound), below floor \(tiny.stats.movesBelowFloor)")
        report("and the same pair is a move once the floor allows it",
               diff(short, shortMoved, floor: 4).stats.movesFound > 0)

        print("        negative control")
        let renamed = diff(before, before.replacingOccurrences(of: "helper", with: "helperFn"))
        report("a rename is never reported as a move", renamed.stats.movesFound == 0,
               "\(renamed.stats.movesFound) moves")
    }

    print("\n=== M6-D corpus: does the move search fire on real files, and only there? ===")
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()
        let floors = [4, 8, 12, 24]
        var movedFiles = [Int](repeating: 0, count: floors.count)
        var falseFiles = [Int](repeating: 0, count: floors.count)
        var agreementFailures = 0
        var checked = 0

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == "tsx" else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 400, size < 40_000,
                      let data = try? Data(contentsOf: url),
                      let text = String(bytes: [UInt8](data), encoding: .utf8) else { continue }

                // Relocation without modification: the imports move to the end of the file.
                let lines = text.components(separatedBy: "\n")
                let imports = lines.filter { $0.hasPrefix("import ") }
                guard imports.count >= 2 else { continue }
                let relocated = (lines.filter { !$0.hasPrefix("import ") } + imports).joined(separator: "\n")
                let renamed = text.replacingOccurrences(of: "className", with: "class_Name")
                guard relocated != text, renamed != text else { continue }

                let name = url.lastPathComponent
                for (index, floor) in floors.enumerated() {
                    let settings = MatcherSettings(moveContentFloor: floor)
                    let moved = structuralDiff(oldPath: name, oldBytes: [UInt8](data),
                                               newPath: name, newBytes: [UInt8](relocated.utf8),
                                               parser: parser, settings: settings)
                    let control = structuralDiff(oldPath: name, oldBytes: [UInt8](data),
                                                 newPath: name, newBytes: [UInt8](renamed.utf8),
                                                 parser: parser, settings: settings)
                    if moved.stats.movesFound > 0 { movedFiles[index] += 1 }
                    if control.stats.movesFound > 0 { falseFiles[index] += 1 }
                    if !movedContentAgrees(moved) || !movedContentAgrees(control) { agreementFailures += 1 }
                }

                checked += 1
                if checked >= 120 { break }
            }
        }

        report("files with relocatable imports were found", checked > 0, "\(checked) files")
        guard checked > 0 else { return }
        print("        floor   files with a move   files where a rename faked one")
        for (index, floor) in floors.enumerated() {
            print(String(format: "        %4d B   %13d/%d   %26d", floor, movedFiles[index], checked, falseFiles[index]))
        }
        let shipped = floors.firstIndex(of: moveContentFloor) ?? 0
        report("relocation is recognised on most real files",
               Double(movedFiles[shipped]) / Double(checked) > 0.5,
               "\(movedFiles[shipped]) of \(checked)")
        report("a rename never fakes a move at the shipped floor", falseFiles[shipped] == 0,
               "\(falseFiles[shipped]) files")
        report("every move in the corpus is byte-identical across sides", agreementFailures == 0,
               "\(agreementFailures) disagreements")
    }
}
