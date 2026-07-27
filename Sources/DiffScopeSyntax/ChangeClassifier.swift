import DiffScopeEngine
import Foundation

private let whitespaceBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]

private func dropWhitespace(_ bytes: [UInt8]) -> [UInt8] {
    bytes.filter { !whitespaceBytes.contains($0) }
}

private func unifyQuotes(_ bytes: [UInt8]) -> [UInt8] {
    bytes.map { $0 == 0x27 || $0 == 0x60 ? 0x22 : $0 }
}

private func dropTrailingCommas(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for (index, byte) in bytes.enumerated() {
        if byte == 0x2C {
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if next == nil || next == 0x29 || next == 0x7D || next == 0x5D { continue }
        }
        out.append(byte)
    }
    return out
}

private func dropParentheses(_ bytes: [UInt8]) -> [UInt8] {
    bytes.filter { $0 != 0x28 && $0 != 0x29 }
}

private func commaSeparatedItems(_ bytes: [UInt8]) -> [[UInt8]] {
    var items: [[UInt8]] = []
    var current: [UInt8] = []
    var depth = 0
    for byte in bytes {
        switch byte {
        case 0x28, 0x5B, 0x7B: depth += 1
        case 0x29, 0x5D, 0x7D: depth -= 1
        case 0x2C where depth == 0:
            items.append(current)
            current = []
            continue
        default: break
        }
        current.append(byte)
    }
    items.append(current)
    return items.map(dropWhitespace).filter { !$0.isEmpty }
}

/// A changed span often arrives wrapped — `f(a, b)`, `[a, b]`, `{ a, b }` — so a single
/// top-level item is retried against the contents of the outermost bracket pair.
private func reorderableItems(_ bytes: [UInt8]) -> [[UInt8]] {
    let items = commaSeparatedItems(bytes)
    guard items.count <= 1 else { return items }
    guard let open = bytes.firstIndex(where: { $0 == 0x28 || $0 == 0x5B || $0 == 0x7B }) else { return items }
    var depth = 0
    for index in open..<bytes.count {
        switch bytes[index] {
        case 0x28, 0x5B, 0x7B: depth += 1
        case 0x29, 0x5D, 0x7D:
            depth -= 1
            if depth == 0 {
                return index > open + 1 ? commaSeparatedItems(Array(bytes[(open + 1)..<index])) : items
            }
        default: break
        }
    }
    return items
}

/// Classifies one aligned pair of changed spans. Purely presentational: the label affects
/// grouping and nothing else, and a wrong `formatting-only` claim is a trust defect, so every
/// detector is an equality test after a normalisation that provably preserves the bytes it
/// ignores. First match wins; anything unrecognised stays unclassified.
public func changeClassification(old: [UInt8], new: [UInt8]) -> ChangeClass? {
    guard old != new else { return nil }

    let oldBare = dropWhitespace(old)
    let newBare = dropWhitespace(new)
    if oldBare == newBare { return .whitespace }

    if unifyQuotes(oldBare) == unifyQuotes(newBare) { return .quoteStyle }
    if dropTrailingCommas(oldBare) == dropTrailingCommas(newBare) { return .trailingComma }
    if dropParentheses(oldBare) == dropParentheses(newBare) { return .parenOnly }

    let oldItems = reorderableItems(old)
    let newItems = reorderableItems(new)
    if oldItems.count > 1, oldItems.count == newItems.count, oldItems != newItems,
       oldItems.sorted(by: lexicographicallyPrecedes) == newItems.sorted(by: lexicographicallyPrecedes) {
        return .reordering
    }

    return nil
}

private func lexicographicallyPrecedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    a.lexicographicallyPrecedes(b)
}
