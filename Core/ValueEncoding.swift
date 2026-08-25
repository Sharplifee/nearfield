import Foundation

/// How a user-entered string becomes bytes on the wire.
/// Lives here rather than in the Shortcuts layer because the in-app write editor is the
/// primary consumer; Shortcuts (v1.1) will reuse it rather than redefine it.
enum ValueEncoding: String, CaseIterable, Identifiable, Sendable {
    case text, number, hex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Text"; case .number: "Number"; case .hex: "Hex"
        }
    }
}

enum ValueEncoder {
    static func encode(_ string: String, as encoding: ValueEncoding) -> Data? {
        switch encoding {
        case .text:   string.data(using: .utf8)
        case .number: UInt64(string).map { withUnsafeBytes(of: $0.littleEndian) { Data($0) } }
        case .hex:    hex(string)
        }
    }

    /// Accepts "1A2B", "1a 2b", "0x1A2B". Rejects odd-length input rather than padding,
    /// because silently padding a hex write is how you brick a peripheral.
    static func hex(_ s: String) -> Data? {
        let cleaned = s.replacingOccurrences(of: " ", with: "")
                       .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var out = Data(capacity: cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let byte = UInt8(cleaned[i..<j], radix: 16) else { return nil }
            out.append(byte); i = j
        }
        return out
    }
}
