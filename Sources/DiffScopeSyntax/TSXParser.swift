import CTreeSitter
import CTreeSitterTSX
import DiffScopeEngine
import Foundation

public struct SyntaxLeaf: Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let type: String
    public let isMissing: Bool
    public let isError: Bool
}

public struct ParseOutcome: Sendable {
    public let leaves: [SyntaxLeaf]
    public let hasErrorNodes: Bool
    public let rootEndByte: Int
    public let byteCount: Int
}

public final class TSXParser {
    private let parser: OpaquePointer

    public init?() {
        guard let parser = ts_parser_new() else { return nil }
        guard ts_parser_set_language(parser, tree_sitter_tsx()) else {
            ts_parser_delete(parser)
            return nil
        }
        self.parser = parser
    }

    deinit { ts_parser_delete(parser) }

    func parseRaw(_ bytes: [UInt8]) -> OpaquePointer? {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return ts_parser_parse_string(
                parser, nil,
                UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                UInt32(buffer.count)
            )
        }
    }

    public func parse(_ bytes: [UInt8]) -> ParseOutcome? {
        guard !bytes.isEmpty else {
            return ParseOutcome(leaves: [], hasErrorNodes: false, rootEndByte: 0, byteCount: 0)
        }
        let tree: OpaquePointer? = bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return ts_parser_parse_string(
                parser, nil,
                UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                UInt32(buffer.count)
            )
        }
        guard let tree else { return nil }
        defer { ts_tree_delete(tree) }

        let root = ts_tree_root_node(tree)
        var leaves: [SyntaxLeaf] = []
        var sawError = false
        collectLeaves(root, into: &leaves, sawError: &sawError)
        leaves.sort { $0.start < $1.start || ($0.start == $1.start && $0.end < $1.end) }

        return ParseOutcome(
            leaves: leaves,
            hasErrorNodes: sawError,
            rootEndByte: Int(ts_node_end_byte(root)),
            byteCount: bytes.count
        )
    }

    private func collectLeaves(_ node: TSNode, into leaves: inout [SyntaxLeaf], sawError: inout Bool) {
        let type = String(cString: ts_node_type(node))
        let missing = ts_node_is_missing(node)
        let isError = type == "ERROR" || ts_node_has_error(node) && ts_node_child_count(node) == 0
        if type == "ERROR" || missing { sawError = true }

        let count = ts_node_child_count(node)
        if count == 0 {
            leaves.append(SyntaxLeaf(
                start: Int(ts_node_start_byte(node)),
                end: Int(ts_node_end_byte(node)),
                type: type,
                isMissing: missing,
                isError: isError
            ))
            return
        }
        for index in 0..<count {
            collectLeaves(ts_node_child(node, index), into: &leaves, sawError: &sawError)
        }
    }
}
