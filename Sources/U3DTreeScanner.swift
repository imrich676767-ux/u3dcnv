import Foundation

enum U3DTreeScanner {
    static func collectFiles(in rootURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                results.append(item)
            }
        }
        return results
    }

    static func relativePath(for fileURL: URL, under rootURL: URL) -> String {
        let raw = fileURL.path.replacingOccurrences(of: rootURL.path, with: "")
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    static func verifyOutputs(files: [URL], inputRoot: URL, outputRoot: URL) -> (verified: Int, logs: [String]) {
        let fm = FileManager.default
        var verified = 0
        var logs: [String] = []

        for sourceURL in files {
            let rel = relativePath(for: sourceURL, under: inputRoot)
            let destURL = outputRoot.appendingPathComponent(rel)
            if fm.fileExists(atPath: destURL.path) {
                verified += 1
            } else {
                logs.append("❌ Missing output: \(rel)")
            }
        }
        logs.append("✅ Post-check complete: \(verified)/\(files.count) files verified.")
        return (verified, logs)
    }
}
