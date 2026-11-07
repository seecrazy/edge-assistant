import Foundation
import CryptoKit

/// 模型资产，与 JS `validateModelAsset` 校验的元数据对齐。
public struct ModelAsset: Codable, Equatable, Sendable {
    public let id: String
    public let tier: ModelTier
    public let version: String
    public let sha256: String
    public let sizeBytes: Int
    public let capabilities: [CapabilityMode]
    /// 商店已安装模型的本机目录；内置模拟资产为 nil。
    public let localDirectory: URL?
    /// 商店快照的模型格式（如 `mlx-4bit`）；内置模拟资产为 nil。
    public let format: String?
    /// 兼容性检查识别的 HuggingFace model_type；内置模拟资产为 nil。
    public let modelType: String?

    public init(
        id: String,
        tier: ModelTier,
        version: String,
        sha256: String,
        sizeBytes: Int,
        capabilities: [CapabilityMode],
        localDirectory: URL? = nil,
        format: String? = nil,
        modelType: String? = nil
    ) {
        self.id = id
        self.tier = tier
        self.version = version
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.capabilities = capabilities
        self.localDirectory = localDirectory
        self.format = format
        self.modelType = modelType
    }
}

public struct AssetValidation: Equatable, Sendable {
    public let isValid: Bool
    public let errors: [String]
}

public enum ModelAssetValidator {
    public static func validate(_ asset: ModelAsset) -> AssetValidation {
        var errors: [String] = []

        if asset.id.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("id is required")
        }
        if asset.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil {
            errors.append("version must be semver x.y.z")
        }
        if asset.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) == nil {
            errors.append("sha256 must be 64 hex chars")
        }
        if asset.sizeBytes <= 0 {
            errors.append("sizeBytes must be positive")
        }
        if asset.capabilities.isEmpty {
            errors.append("capabilities are required")
        }
        return AssetValidation(isValid: errors.isEmpty, errors: errors)
    }
}

public struct AssetVerification: Equatable, Sendable {
    public let isValid: Bool
    public let reason: String?
    public let expectedSHA256: String?
    public let actualSHA256: String?
}

public enum SHA256Verifier {
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(asset: ModelAsset, bytes: Data) -> AssetVerification {
        let actual = hexDigest(of: bytes)
        guard actual == asset.sha256.lowercased() else {
            return AssetVerification(
                isValid: false,
                reason: "sha256 mismatch",
                expectedSHA256: asset.sha256.lowercased(),
                actualSHA256: actual
            )
        }
        return AssetVerification(isValid: true, reason: nil, expectedSHA256: actual, actualSHA256: actual)
    }

    /// 大权重必须流式摘要，避免数 GB 文件读入内存。
    public static func fileDigest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 商店大文件校验使用 cooperative async；周期 yield 避免高优先级 CPU 占满触发系统保护。
    public static func fileDigestAsync(at url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var chunkIndex = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
            chunkIndex += 1
            if chunkIndex % 16 == 0 {
                await Task.yield()
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
