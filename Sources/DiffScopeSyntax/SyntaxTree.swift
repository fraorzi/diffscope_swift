import CTreeSitter
import CTreeSitterTSX
import Foundation

public struct SyntaxNode: Sendable {
    public let id: Int
    public let parent: Int?
    public let children: [Int]
    public let start: Int
    public let end: Int
    public let type: String
    public let isLeaf: Bool
    public let isError: Bool
    public let height: Int
    public let descendantCount: Int
    public let structuralHash: UInt64
}

public struct SyntaxTree: Sendable {
    public let nodes: [SyntaxNode]
    public let rootID: Int?
    public let bytes: [UInt8]

    public func node(_ id: Int) -> SyntaxNode { nodes[id] }

    public func descendants(of id: Int) -> [Int] {
        var out: [Int] = []
        var stack = [id]
        while let current = stack.popLast() {
            out.append(current)
            stack.append(contentsOf: nodes[current].children)
        }
        return out
    }

    public func text(of id: Int) -> [UInt8] {
        let node = nodes[id]
        guard node.start < node.end, node.end <= bytes.count else { return [] }
        return Array(bytes[node.start..<node.end])
    }
}

extension TSXParser {
    public func parseTree(_ source: [UInt8]) -> SyntaxTree? {
        guard !source.isEmpty else { return SyntaxTree(nodes: [], rootID: nil, bytes: source) }
        guard let raw = parseRaw(source) else { return nil }
        defer { ts_tree_delete(raw) }
        var builder = TreeBuilder(bytes: source)
        let root = builder.add(ts_tree_root_node(raw), parent: nil)
        return SyntaxTree(nodes: builder.nodes, rootID: root, bytes: source)
    }
}

private struct TreeBuilder {
    let bytes: [UInt8]
    var nodes: [SyntaxNode] = []

    mutating func add(_ tsNode: TSNode, parent: Int?) -> Int {
        let id = nodes.count
        let type = String(cString: ts_node_type(tsNode))
        let start = Int(ts_node_start_byte(tsNode))
        let end = Int(ts_node_end_byte(tsNode))
        let isError = type == "ERROR" || ts_node_is_missing(tsNode)

        nodes.append(SyntaxNode(
            id: id, parent: parent, children: [], start: start, end: end,
            type: type, isLeaf: true, isError: isError,
            height: 1, descendantCount: 1, structuralHash: 0
        ))

        var childIDs: [Int] = []
        let count = ts_node_child_count(tsNode)
        for index in 0..<count {
            childIDs.append(add(ts_node_child(tsNode, index), parent: id))
        }

        var height = 1
        var descendants = 1
        var hasher = FNV()
        hasher.combine(type)
        if childIDs.isEmpty {
            hasher.combine(bytes: start < end && end <= bytes.count ? Array(bytes[start..<end]) : [])
        }
        for child in childIDs {
            height = max(height, nodes[child].height + 1)
            descendants += nodes[child].descendantCount
            hasher.combine(hash: nodes[child].structuralHash)
        }

        nodes[id] = SyntaxNode(
            id: id, parent: parent, children: childIDs, start: start, end: end,
            type: type, isLeaf: childIDs.isEmpty, isError: isError,
            height: height, descendantCount: descendants, structuralHash: hasher.value
        )
        return id
    }
}

struct FNV {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    mutating func combine(_ text: String) {
        combine(bytes: Array(text.utf8))
    }

    mutating func combine(bytes: [UInt8]) {
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        value ^= 0xff
        value = value &* 0x100000001b3
    }

    mutating func combine(hash: UInt64) {
        var remaining = hash
        for _ in 0..<8 {
            value ^= UInt64(remaining & 0xff)
            value = value &* 0x100000001b3
            remaining >>= 8
        }
    }
}
