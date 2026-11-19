import Foundation

enum U3DConstants {
    static let targetAndroid: UInt32 = 13
    static let targetIOS: UInt32 = 9

    static let soundBankExtensions: Set<String> = [
        "bnk", "wem", "pck", "bank"
    ]

    static let textureHints: [String] = [
        "ASTC", "PVRTC", "PVR!"
    ]

    static let rawStreamSuffixes: [String] = [
        ".resS", ".resource"
    ]
}
