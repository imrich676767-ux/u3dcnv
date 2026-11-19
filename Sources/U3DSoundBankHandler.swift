import Foundation

enum U3DSoundBankHandler {
    static func isSoundBank(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return U3DConstants.soundBankExtensions.contains(ext)
    }

    static func copyByteForByte(from sourceURL: URL, to destURL: URL) throws -> Int {
        let fm = FileManager.default
        let rawBytes = try Data(contentsOf: sourceURL)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try rawBytes.write(to: destURL, options: .atomic)
        return rawBytes.count
    }
}
