import Foundation

public enum Utf16MappingError: Error, Equatable, CustomStringConvertible {
    case invalidUTF8(atByte: Int)
    case offsetOutOfRange(Int, length: Int)
    case offsetSplitsCharacter(Int)

    public var description: String {
        switch self {
        case let .invalidUTF8(offset): return "content is not valid UTF-8 at byte \(offset)"
        case let .offsetOutOfRange(offset, length): return "byte offset \(offset) out of range 0...\(length)"
        case let .offsetSplitsCharacter(offset): return "byte offset \(offset) falls inside a UTF-8 sequence"
        }
    }
}

public struct Utf16OffsetMapper {
    private let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public func map(byteOffsets: [Int]) throws -> [Int: Int] {
        guard !byteOffsets.isEmpty else { return [:] }
        let wanted = Set(byteOffsets)
        for offset in wanted where offset < 0 || offset > bytes.count {
            throw Utf16MappingError.offsetOutOfRange(offset, length: bytes.count)
        }

        var mapping: [Int: Int] = [:]
        var byteIndex = 0
        var utf16Index = 0

        while byteIndex < bytes.count {
            if wanted.contains(byteIndex) { mapping[byteIndex] = utf16Index }

            let lead = bytes[byteIndex]
            let width: Int
            let units: Int

            switch lead {
            case 0x00...0x7F:
                width = 1; units = 1
            case 0xC2...0xDF:
                width = 2; units = 1
            case 0xE0...0xEF:
                width = 3; units = 1
            case 0xF0...0xF4:
                width = 4; units = 2
            default:
                throw Utf16MappingError.invalidUTF8(atByte: byteIndex)
            }

            guard byteIndex + width <= bytes.count else {
                throw Utf16MappingError.invalidUTF8(atByte: byteIndex)
            }
            for continuation in 1..<width where (bytes[byteIndex + continuation] & 0xC0) != 0x80 {
                throw Utf16MappingError.invalidUTF8(atByte: byteIndex + continuation)
            }
            if width > 1 {
                for interior in (byteIndex + 1)..<(byteIndex + width) where wanted.contains(interior) {
                    throw Utf16MappingError.offsetSplitsCharacter(interior)
                }
            }

            byteIndex += width
            utf16Index += units
        }

        if wanted.contains(bytes.count) { mapping[bytes.count] = utf16Index }
        return mapping
    }

    public func utf16Offset(ofByte offset: Int) throws -> Int {
        let mapping = try map(byteOffsets: [offset])
        guard let value = mapping[offset] else {
            throw Utf16MappingError.offsetOutOfRange(offset, length: bytes.count)
        }
        return value
    }

    public var utf16Length: Int {
        (try? utf16Offset(ofByte: bytes.count)) ?? 0
    }

    public var isValidUTF8: Bool {
        (try? map(byteOffsets: [bytes.count])) != nil
    }
}
