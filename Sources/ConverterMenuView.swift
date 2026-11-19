import SwiftUI
import UniformTypeIdentifiers

struct ConverterMenuView: View {
    @State private var settings = ConversionSettings()
    @State private var inputFolderURL: URL?
    @State private var outputFolderURL: URL?
    @State private var isPickingInput = false
    @State private var isPickingOutput = false
    @State private var isConverting = false
    @State private var progressText = "Ready"
    @State private var progressValue: Double = 0
    @State private var report: ConversionReport?
    @State private var errorMessage: String?

    private var isA8PlusSupported: Bool {
        BundleConverterEngine.supportsASTC(requireA8OrNewer: settings.requireA8OrNewerForASTC)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Input & Output Folders") {
                    Button {
                        isPickingInput = true
                    } label: {
                        LabeledContent("Source Folder", value: inputFolderURL?.lastPathComponent ?? "Select Folder")
                    }

                    Button {
                        isPickingOutput = true
                    } label: {
                        LabeledContent("Output Folder", value: outputFolderURL?.lastPathComponent ?? "Select Folder")
                    }
                }

                Section("2. Texture & Sound Bank Rules") {
                    Toggle("Skip ASTC / PVRTC Re-encode", isOn: $settings.skipASTCAndPVRTCReencode)
                    Toggle("Copy Sound Banks Byte-for-Byte", isOn: $settings.copySoundBanksByteForByte)
                    Toggle("Mirror Folder & Verify After Run", isOn: $settings.mirrorFolderAndVerify)
                }

                Section("3. iOS Hardware Requirement") {
                    Toggle("Require A8 (iPhone 6) or Newer for ASTC", isOn: $settings.requireA8OrNewerForASTC)

                    HStack {
                        Image(systemName: isA8PlusSupported ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isA8PlusSupported ? .green : .orange)
                        Text(
                            isA8PlusSupported
                            ? "Device meets A8+ ASTC capability check"
                            : "Older chip detected: prefer PVRTC over ASTC"
                        )
                        .font(.footnote)
                    }
                }

                Section("4. Conversion Progress") {
                    ProgressView(value: progressValue)
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        startConversion()
                    } label: {
                        HStack {
                            Spacer()
                            Text(isConverting ? "Converting..." : "Convert Now")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(isConverting || inputFolderURL == nil || outputFolderURL == nil)
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if let report {
                    Section("Verification & Summary") {
                        LabeledContent("Total Files", value: "\(report.totalFiles)")
                        LabeledContent("Sound Banks Copied", value: "\(report.copiedSoundBanks)")
                        LabeledContent("ASTC/PVRTC Untouched", value: "\(report.passedThroughTextures)")
                        LabeledContent("Verified Output", value: "\(report.verifiedFiles)/\(report.totalFiles)")

                        ForEach(report.logs, id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("u3dconv iOS Menu")
            .fileImporter(isPresented: $isPickingInput, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    inputFolderURL = url
                }
            }
            .fileImporter(isPresented: $isPickingOutput, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    outputFolderURL = url
                }
            }
        }
    }

    private func startConversion() {
        guard let inputURL = inputFolderURL, let outputURL = outputFolderURL else { return }
        errorMessage = nil
        report = nil
        isConverting = true
        progressValue = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let inputAccess = inputURL.startAccessingSecurityScopedResource()
            let outputAccess = outputURL.startAccessingSecurityScopedResource()
            defer {
                if inputAccess { inputURL.stopAccessingSecurityScopedResource() }
                if outputAccess { outputURL.stopAccessingSecurityScopedResource() }
            }

            do {
                let result = try BundleConverterEngine.convertDirectory(
                    inputRoot: inputURL,
                    outputRoot: outputURL,
                    settings: settings
                ) { current, total, fileName in
                    DispatchQueue.main.async {
                        progressValue = Double(current) / Double(total)
                        progressText = "Processing \(fileName) (\(current)/\(total))"
                    }
                }

                DispatchQueue.main.async {
                    report = result
                    progressText = "Completed"
                    isConverting = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    progressText = "Failed"
                    isConverting = false
                }
            }
        }
    }
}
