import Foundation
import Metal

enum U3DTextureRules {
    static func supportsASTC(requireA8OrNewer: Bool) -> Bool {
        guard requireA8OrNewer else { return true }
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple1)
    }

    static func hasASTCOrPVRTCHint(data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let prefixText = String(data: data.prefix(64), encoding: .ascii) ?? ""
        let upper = prefixText.uppercased()
        return U3DConstants.textureHints.contains { upper.contains($0) }
    }
}
