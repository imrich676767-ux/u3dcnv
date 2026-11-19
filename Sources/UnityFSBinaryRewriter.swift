import Foundation
import Compression

enum UnityFSConversionError: LocalizedError {
    case invalidHeader
    case unsupportedCompression(UInt32)
    case decompressionFailed
    case corruptedBlockData

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "File មិនមែនជាទម្រង់ UnityFS AssetBundle ត្រឹមត្រូវទេ"
        case .unsupportedCompression(let type):
            return "ទម្រង់ Compression (\(type)) មិនទាន់គាំទ្រ (គាំទ្រ Uncompressed និង LZ4/LZ4HC)"
        case .decompressionFailed:
            return "បរាជ័យក្នុងការពន្លា LZ4 block របស់ UnityFS"
        case .corruptedBlockData:
            return "ទិន្នន័យ Block ឬ Directory ក្នុង AssetBundle ខូច"
        }
    }
}

struct StorageBlockInfo {
    var uncompressedSize: UInt32
    var compressedSize: UInt32
    var flags: UInt16
}

struct DirectoryNodeInfo {
    var offset: Int64
    var size: Int64
    var flags: UInt32
    var path: String
}

final class BinaryCursor {
    let data: Data
    var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw UnityFSConversionError.corruptedBlockData
        }
        let sub = data.subdata(in: offset..<(offset + count))
        offset += count
        return sub
    }

    func readCString() throws -> String {
        var bytes: [UInt8] = []
        while offset < data.count {
            let b = data[offset]
            offset += 1
            if b == 0 {
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }
            bytes.append(b)
        }
        throw UnityFSConversionError.corruptedBlockData
    }

    func readUInt16BE() throws -> UInt16 {
        let b = try readBytes(2)
        return (UInt16(b[b.startIndex]) << 8) | UInt16(b[b.startIndex + 1])
    }

    func readUInt32BE() throws -> UInt32 {
        let b = try readBytes(4)
        return (UInt32(b[b.startIndex]) << 24) |
               (UInt32(b[b.startIndex + 1]) << 16) |
               (UInt32(b[b.startIndex + 2]) << 8) |
               UInt32(b[b.startIndex + 3])
    }

    func readInt64BE() throws -> Int64 {
        let b = try readBytes(8)
        var val: UInt64 = 0
        for i in 0..<8 {
            val = (val << 8) | UInt64(b[b.startIndex + i])
        }
        return Int64(bitPattern: val)
    }

    func align(_ alignment: Int) {
        let rem = offset % alignment
        if rem != 0 {
            offset += (alignment - rem)
        }
    }
}

final class BinaryWriter {
    var data = Data()

    func writeCString(_ str: String) {
        if let utf8 = str.data(using: .utf8) {
            data.append(utf8)
        }
        data.append(0)
    }

    func writeUInt16BE(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    func writeUInt32BE(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    func writeInt64BE(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((u >> shift) & 0xFF))
        }
    }

    func padToAlignment(_ alignment: Int) {
        let rem = data.count % alignment
        if rem != 0 {
            data.append(Data(repeating: 0, count: alignment - rem))
        }
    }
}

final class UnityFSBinaryRewriter {
    static func isUnityFS(data: Data) -> Bool {
        let stripped = PYHeaderHelper.stripPYHeaderIfPresent(from: data).payload
        guard stripped.count >= 8 else { return false }
        let sig = String(data: stripped.prefix(7), encoding: .ascii)
        return sig == "UnityFS"
    }

    static func convertAndroidBundleToIOS(
        bundleData: Data,
        skipASTCReencode: Bool
    ) throws -> (convertedData: Data, patchedNodes: Int, details: [String]) {
        let headerCheck = PYHeaderHelper.stripPYHeaderIfPresent(from: bundleData)
        let workingData = headerCheck.payload

        guard workingData.count >= 8,
              String(data: workingData.prefix(7), encoding: .ascii) == "UnityFS" else {
            throw UnityFSConversionError.invalidHeader
        }

        let cursor = BinaryCursor(data: workingData)
        let signature = try cursor.readCString()
        let version = try cursor.readUInt32BE()
        let unityVersion = try cursor.readCString()
        let unityRevision = try cursor.readCString()
        _ = try cursor.readInt64BE()
        let compBlocksInfoSize = try cursor.readUInt32BE()
        let uncompBlocksInfoSize = try cursor.readUInt32BE()
        let flags = try cursor.readUInt32BE()

        if version >= 7 {
            cursor.align(16)
        }

        let compressionType = flags & 0x3F
        let blocksInfoAtEnd = (flags & 0x80) != 0

        let compressedBlocksInfo: Data
        let blocksStartOffset: Int

        if blocksInfoAtEnd {
            blocksStartOffset = cursor.offset
            let endInfoStart = workingData.count - Int(compBlocksInfoSize)
            guard endInfoStart >= blocksStartOffset else {
                throw UnityFSConversionError.corruptedBlockData
            }
            compressedBlocksInfo = workingData.subdata(in: endInfoStart..<workingData.count)
        } else {
            compressedBlocksInfo = try cursor.readBytes(Int(compBlocksInfoSize))
            if (flags & 0x200) != 0 {
                cursor.align(16)
            }
            blocksStartOffset = cursor.offset
        }

        let rawBlocksInfo = try decompressBlock(
            compressed: compressedBlocksInfo,
            uncompressedSize: Int(uncompBlocksInfoSize),
            compressionType: compressionType
        )

        let infoCursor = BinaryCursor(data: rawBlocksInfo)
        let uncompressedDataHash = try infoCursor.readBytes(16)
        let blockCount = try infoCursor.readUInt32BE()

        var blocks: [StorageBlockInfo] = []
        for _ in 0..<blockCount {
            let uSize = try infoCursor.readUInt32BE()
            let cSize = try infoCursor.readUInt32BE()
            let bFlags = try infoCursor.readUInt16BE()
            blocks.append(StorageBlockInfo(uncompressedSize: uSize, compressedSize: cSize, flags: bFlags))
        }

        let nodeCount = try infoCursor.readUInt32BE()
        var nodes: [DirectoryNodeInfo] = []
        for _ in 0..<nodeCount {
            let nOffset = try infoCursor.readInt64BE()
            let nSize = try infoCursor.readInt64BE()
            let nFlags = try infoCursor.readUInt32BE()
            let nPath = try infoCursor.readCString()
            nodes.append(DirectoryNodeInfo(offset: nOffset, size: nSize, flags: nFlags, path: nPath))
        }

        var readPos = blocksStartOffset
        var fullAssetStream = Data()
        for block in blocks {
            let cLen = Int(block.compressedSize)
            guard readPos + cLen <= workingData.count else {
                throw UnityFSConversionError.corruptedBlockData
            }
            let slice = workingData.subdata(in: readPos..<(readPos + cLen))
            readPos += cLen

            let bCompType = UInt32(block.flags & 0x3F)
            let decompressed = try decompressBlock(
                compressed: slice,
                uncompressedSize: Int(block.uncompressedSize),
                compressionType: bCompType
            )
            fullAssetStream.append(decompressed)
        }

        var logs: [String] = []
        var patchedCount = 0

        for node in nodes {
            let start = Int(node.offset)
            let end = start + Int(node.size)
            guard start >= 0, end <= fullAssetStream.count else { continue }

            if U3DConstants.rawStreamSuffixes.contains(where: { node.path.hasSuffix($0) }) {
                logs.append("🎞️ Raw stream preserved: \(node.path) (\(node.size) bytes)")
                continue
            }

            var nodeSlice = fullAssetStream.subdata(in: start..<end)
            if patchSerializedFilePlatform(&nodeSlice, skipASTCNote: skipASTCReencode) {
                fullAssetStream.replaceSubrange(start..<end, with: nodeSlice)
                patchedCount += 1
                logs.append("🔧 Patched SerializedFile Target Android(13) -> iOS(9): \(node.path)")
            } else {
                logs.append("ℹ️ Node kept intact: \(node.path)")
            }
        }

        let newInfoWriter = BinaryWriter()
        newInfoWriter.data.append(uncompressedDataHash)
        newInfoWriter.writeUInt32BE(1)
        newInfoWriter.writeUInt32BE(UInt32(fullAssetStream.count))
        newInfoWriter.writeUInt32BE(UInt32(fullAssetStream.count))
        newInfoWriter.writeUInt16BE(0x0040)

        newInfoWriter.writeUInt32BE(UInt32(nodes.count))
        for n in nodes {
            newInfoWriter.writeInt64BE(n.offset)
            newInfoWriter.writeInt64BE(n.size)
            newInfoWriter.writeUInt32BE(n.flags)
            newInfoWriter.writeCString(n.path)
        }

        let newBlocksInfoData = newInfoWriter.data
        let newFlags: UInt32 = 0x0040

        let headerWriter = BinaryWriter()
        headerWriter.writeCString(signature)
        headerWriter.writeUInt32BE(version)
        headerWriter.writeCString(unityVersion)
        headerWriter.writeCString(unityRevision)

        let sizePlaceholderOffset = headerWriter.data.count
        headerWriter.writeInt64BE(0)
        headerWriter.writeUInt32BE(UInt32(newBlocksInfoData.count))
        headerWriter.writeUInt32BE(UInt32(newBlocksInfoData.count))
        headerWriter.writeUInt32BE(newFlags)

        if version >= 7 {
            headerWriter.padToAlignment(16)
        }

        headerWriter.data.append(newBlocksInfoData)
        headerWriter.data.append(fullAssetStream)

        let finalSize = Int64(headerWriter.data.count)
        let uFinal = UInt64(bitPattern: finalSize)
        for (i, shift) in stride(from: 56, through: 0, by: -8).enumerated() {
            headerWriter.data[sizePlaceholderOffset + i] = UInt8((uFinal >> shift) & 0xFF)
        }

        var outputData = headerWriter.data
        if headerCheck.headerFound {
            outputData = PYHeaderHelper.prependPYHeader(to: outputData)
            logs.append("🏷️ Preserved PY000000\x00\x03 prefix header")
        }

        return (outputData, patchedCount, logs)
    }

    private static func patchSerializedFilePlatform(_ data: inout Data, skipASTCNote: Bool) -> Bool {
        guard data.count >= 48 else { return false }

        let versionBE = (UInt32(data[8]) << 24) |
                        (UInt32(data[9]) << 16) |
                        (UInt32(data[10]) << 8) |
                        UInt32(data[11])

        guard versionBE >= 14 && versionBE <= 30 else { return false }

        let endianness = data[16]
        var idx = versionBE >= 22 ? 36 : 20

        while idx < data.count && data[idx] != 0 {
            idx += 1
        }
        idx += 1

        guard idx + 4 <= data.count else { return false }

        let currentTarget: UInt32
        if endianness == 0 {
            currentTarget = UInt32(data[idx]) |
                            (UInt32(data[idx + 1]) << 8) |
                            (UInt32(data[idx + 2]) << 16) |
                            (UInt32(data[idx + 3]) << 24)
        } else {
            currentTarget = (UInt32(data[idx]) << 24) |
                            (UInt32(data[idx + 1]) << 16) |
                            (UInt32(data[idx + 2]) << 8) |
                            UInt32(data[idx + 3])
        }

        if currentTarget == U3DConstants.targetAndroid {
            if endianness == 0 {
                data[idx] = UInt8(U3DConstants.targetIOS & 0xFF)
                data[idx + 1] = UInt8((U3DConstants.targetIOS >> 8) & 0xFF)
                data[idx + 2] = UInt8((U3DConstants.targetIOS >> 16) & 0xFF)
                data[idx + 3] = UInt8((U3DConstants.targetIOS >> 24) & 0xFF)
            } else {
                data[idx] = UInt8((U3DConstants.targetIOS >> 24) & 0xFF)
                data[idx + 1] = UInt8((U3DConstants.targetIOS >> 16) & 0xFF)
                data[idx + 2] = UInt8((U3DConstants.targetIOS >> 8) & 0xFF)
                data[idx + 3] = UInt8(U3DConstants.targetIOS & 0xFF)
            }
            return true
        }
        return false
    }

    private static func decompressBlock(
        compressed: Data,
        uncompressedSize: Int,
        compressionType: UInt32
    ) throws -> Data {
        switch compressionType {
        case 0:
            return compressed
        case 2, 3:
            var dst = Data(count: uncompressedSize)
            let decodedCount = dst.withUnsafeMutableBytes { dstPtr -> Int in
                compressed.withUnsafeBytes { srcPtr -> Int in
                    guard let dBase = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                          let sBase = srcPtr.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(
                        dBase,
                        uncompressedSize,
                        sBase,
                        compressed.count,
                        nil,
                        COMPRESSION_LZ4_RAW
                    )
                }
            }
            guard decodedCount == uncompressedSize else {
                throw UnityFSConversionError.decompressionFailed
            }
            return dst
        default:
            throw UnityFSConversionError.unsupportedCompression(compressionType)
        }
    }
}
