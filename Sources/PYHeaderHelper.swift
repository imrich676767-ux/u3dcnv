import Foundation

enum PYHeaderHelper {
    /// Byte sequence matching Python: b'PY000000\x00\x03'
    static let pyHeaderBytes: [UInt8] = [
        0x50, 0x59,                         // "PY"
        0x30, 0x30, 0x30, 0x30, 0x30, 0x30, // "000000"
        0x00, 0x03                          // \x00\x03
    ]

    static var pyHeaderData: Data {
        Data(pyHeaderBytes)
    }

    static func hasPYHeader(data: Data) -> Bool {
        guard data.count >= pyHeaderBytes.count else { return false }
        return Array(data.prefix(pyHeaderBytes.count)) == pyHeaderBytes
    }

    static func prependPYHeader(to payload: Data) -> Data {
        var out = Data()
        out.append(pyHeaderData)
        out.append(payload)
        return out
    }

    static func stripPYHeaderIfPresent(from data: Data) -> (headerFound: Bool, payload: Data) {
        if hasPYHeader(data: data) {
            return (true, data.subdata(in: pyHeaderBytes.count..<data.count))
        }
        return (false, data)
    }
}
