import Foundation
import Metal

struct ConversionSettings {
    var skipASTCAndPVRTCReencode: Bool = true
    var copySoundBanksByteForByte: Bool = true
    var mirrorFolderAndVerify: Bool = true
    var requireA8OrNewerForASTC: Bool = true
}

struct ConversionReport {
    var totalFiles: Int = 0
    var copiedSoundBanks: Int = 0
    var passedThroughTextures: Int = 0
    var processedBundles: Int = 0
    var verifiedFiles: Int = 0
    var logs: [String] = []
}

final class BundleConverterEngine {
    static func supportsASTC(requireA8OrNewer: Bool) -> Bool {
        guard requireA8OrNewer else { return true }
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple1)
    }

    static func isSoundBank(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["bnk", "wem", "pck", "bank"].contains(ext)
    }

    static func hasASTCOrPVRTCHint(data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let asciiPrefix = String(data: data.prefix(64), encoding: .ascii) ?? ""
        let upper = asciiPrefix.uppercased()
        return upper.contains("ASTC") || upper.contains("PVRTC") || upper.contains("PVR!")
    }

    static func convertDirectory(
        inputRoot: URL,
        outputRoot: URL,
        settings: ConversionSettings,
        onProgress: @escaping (Int, Int, String) -> Void
    ) throws -> ConversionReport {
        var report = ConversionReport()
        let fm = FileManager.default

        let astcSupported = supportsASTC(requireA8OrNewer: settings.requireA8OrNewerForASTC)
        if !astcSupported {
            report.logs.append("⚠️ Warning: Device does not meet A8+ Metal requirement for ASTC; consider PVRTC.")
        }

        let enumerator = fm.enumerator(
            at: inputRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var fileURLs: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                fileURLs.append(item)
            }
        }

        report.totalFiles = fileURLs.count

        for (index, sourceURL) in fileURLs.enumerated() {
            let relativePath = sourceURL.path.replacingOccurrences(of: inputRoot.path, with: "")
            let cleanRelative = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
            let destURL = outputRoot.appendingPathComponent(cleanRelative)

            onProgress(index + 1, max(fileURLs.count, 1), sourceURL.lastPathComponent)

            if settings.mirrorFolderAndVerify {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            if isSoundBank(url: sourceURL) && settings.copySoundBanksByteForByte {
                let rawBytes = try Data(contentsOf: sourceURL)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try rawBytes.write(to: destURL, options: .atomic)
                report.copiedSoundBanks += 1
                report.logs.append("🔊 Byte-copy sound bank: \(cleanRelative) (\(rawBytes.count) bytes)")
                continue
            }

            let fileData = try Data(contentsOf: sourceURL)
            if settings.skipASTCAndPVRTCReencode && hasASTCOrPVRTCHint(data: fileData) {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fileData.write(to: destURL, options: .atomic)
                report.passedThroughTextures += 1
                report.logs.append("🖼️ Untouched ASTC/PVRTC asset: \(cleanRelative)")
                continue
            }

            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fileData.write(to: destURL, options: .atomic)
            report.processedBundles += 1
            report.logs.append("📦 Processed bundle: \(cleanRelative)")
        }

        if settings.mirrorFolderAndVerify {
            var verified = 0
            for sourceURL in fileURLs {
                let relativePath = sourceURL.path.replacingOccurrences(of: inputRoot.path, with: "")
                let cleanRelative = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
                let destURL = outputRoot.appendingPathComponent(cleanRelative)

                let srcSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.intValue
                let dstSize = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? NSNumber)?.intValue

                if fm.fileExists(atPath: destURL.path), let s = srcSize, let d = dstSize, s == d {
                    verified += 1
                } else {
                    report.logs.append("❌ Verification mismatch: \(cleanRelative)")
                }
            }
            report.verifiedFiles = verified
            report.logs.append("✅ Post-check complete: \(verified)/\(fileURLs.count) files verified.")
        }

        return report
    }
}
