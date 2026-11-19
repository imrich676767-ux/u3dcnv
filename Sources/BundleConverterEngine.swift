import Foundation

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
        U3DTextureRules.supportsASTC(requireA8OrNewer: requireA8OrNewer)
    }

    static func isSoundBank(url: URL) -> Bool {
        U3DSoundBankHandler.isSoundBank(url: url)
    }

    static func convertDirectory(
        inputRoot: URL,
        outputRoot: URL,
        settings: ConversionSettings,
        onProgress: @escaping (Int, Int, String) -> Void
    ) throws -> ConversionReport {
        var report = ConversionReport()
        let fm = FileManager.default

        let astcSupported = U3DTextureRules.supportsASTC(requireA8OrNewer: settings.requireA8OrNewerForASTC)
        if !astcSupported {
            report.logs.append("⚠️ Warning: Device does not meet A8+ Metal requirement for ASTC; consider PVRTC.")
        }

        let fileURLs = try U3DTreeScanner.collectFiles(in: inputRoot)
        report.totalFiles = fileURLs.count

        for (index, sourceURL) in fileURLs.enumerated() {
            let cleanRelative = U3DTreeScanner.relativePath(for: sourceURL, under: inputRoot)
            let destURL = outputRoot.appendingPathComponent(cleanRelative)

            onProgress(index + 1, max(fileURLs.count, 1), sourceURL.lastPathComponent)

            if settings.mirrorFolderAndVerify {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }

            if U3DSoundBankHandler.isSoundBank(url: sourceURL) && settings.copySoundBanksByteForByte {
                let byteCount = try U3DSoundBankHandler.copyByteForByte(from: sourceURL, to: destURL)
                report.copiedSoundBanks += 1
                report.logs.append("🔊 Byte-copy sound bank: \(cleanRelative) (\(byteCount) bytes)")
                continue
            }

            let fileData = try Data(contentsOf: sourceURL)

            if UnityFSBinaryRewriter.isUnityFS(data: fileData) {
                do {
                    let result = try UnityFSBinaryRewriter.convertAndroidBundleToIOS(
                        bundleData: fileData,
                        skipASTCReencode: settings.skipASTCAndPVRTCReencode
                    )
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try result.convertedData.write(to: destURL, options: .atomic)
                    report.processedBundles += 1
                    if settings.skipASTCAndPVRTCReencode {
                        report.passedThroughTextures += result.patchedNodes
                    }
                    report.logs.append("✅ UnityFS Converted (\(result.patchedNodes) nodes patched): \(cleanRelative)")
                    report.logs.append(contentsOf: result.details)
                } catch {
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }
                    try fileData.write(to: destURL, options: .atomic)
                    report.logs.append("⚠️ Fallback copy (\(error.localizedDescription)): \(cleanRelative)")
                }
                continue
            }

            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fileData.write(to: destURL, options: .atomic)
            report.processedBundles += 1
            report.logs.append("📄 Copied asset/config: \(cleanRelative)")
        }

        if settings.mirrorFolderAndVerify {
            let check = U3DTreeScanner.verifyOutputs(files: fileURLs, inputRoot: inputRoot, outputRoot: outputRoot)
            report.verifiedFiles = check.verified
            report.logs.append(contentsOf: check.logs)
        }

        return report
    }
}
