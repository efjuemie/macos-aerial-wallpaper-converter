import CryptoKit
import Foundation

struct EncoderAssetManifest: Codable, Equatable, Sendable {
    let version: Int
    let architecture: String
    let files: [String: String]
}

enum EncoderAssetSelector {
    static let binaryRelativePath = "bin/encode_temporal"
    static let manifestRelativePath = "manifest.json"

    static func binaryURL(resourcesRoot: URL) -> URL {
        resourcesRoot
            .appendingPathComponent("Encoder", isDirectory: true)
            .appendingPathComponent(binaryRelativePath)
    }

    static func manifestURL(resourcesRoot: URL) -> URL {
        resourcesRoot
            .appendingPathComponent("Encoder", isDirectory: true)
            .appendingPathComponent(manifestRelativePath)
    }
}

enum EncoderAssetValidator {
    static let expectedArchitecture = "arm64"

    static func validate(
        binaryURL: URL,
        manifestURL: URL,
        actualArchitecture: String
    ) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
            throw AppError("应用内置编码器缺失或不可执行，请重新下载应用。")
        }
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw AppError("应用内置编码器 manifest 缺失，请重新下载应用。")
        }
        let manifest: EncoderAssetManifest
        do {
            manifest = try JSONDecoder().decode(
                EncoderAssetManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw AppError("应用内置编码器 manifest 损坏，请重新下载应用。")
        }
        guard manifest.version == 1,
              manifest.architecture == expectedArchitecture else {
            throw AppError("应用内置编码器版本或架构不匹配，请重新下载应用。")
        }
        let actualArchitectures = actualArchitecture
            .split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "," }
            .map(String.init)
        guard actualArchitectures.contains(expectedArchitecture) else {
            throw AppError("应用内置编码器不是 arm64 架构，请重新下载 Apple Silicon 版本。")
        }
        guard let expectedHash = manifest.files[EncoderAssetSelector.binaryRelativePath],
              expectedHash.count == 64 else {
            throw AppError("应用内置编码器 manifest 缺少 SHA-256，请重新下载应用。")
        }
        let actualHash = try sha256(binaryURL)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw AppError("应用内置编码器完整性校验失败，请重新下载应用。")
        }
        return "内置 arm64 编码器可用（SHA-256 \(actualHash)）"
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum EncoderArchitectureDetector {
    private static let arm64CPU: UInt32 = 0x0100000c
    private static let x86_64CPU: UInt32 = 0x01000007

    static func architecture(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 8 else {
            throw AppError("应用内置编码器文件不完整，请重新下载应用。")
        }
        let magic = data.prefix(4)
        if magic.elementsEqual([0xcf, 0xfa, 0xed, 0xfe]) {
            return architecture(for: readUInt32LE(data, at: 4))
        }
        if magic.elementsEqual([0xca, 0xfe, 0xba, 0xbe]) {
            let count = readUInt32BE(data, at: 4)
            guard count <= 64 else {
                throw AppError("应用内置编码器架构表损坏，请重新下载应用。")
            }
            for index in 0..<Int(count) {
                let offset = 8 + index * 20
                guard offset + 4 <= data.count else {
                    throw AppError("应用内置编码器架构表不完整，请重新下载应用。")
                }
                let architecture = architecture(for: readUInt32BE(data, at: offset))
                if architecture == "arm64" { return architecture }
            }
            return "unknown"
        }
        throw AppError("应用内置编码器不是有效的 Mach-O 文件，请重新下载应用。")
    }

    private static func architecture(for cpuType: UInt32) -> String {
        switch cpuType {
        case arm64CPU: return "arm64"
        case x86_64CPU: return "x86_64"
        default: return "unknown"
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
