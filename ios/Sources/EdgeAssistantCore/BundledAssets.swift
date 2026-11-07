import Foundation

// MARK: - 自带资产目录（安装即内置的读取入口）

public struct BundledAssetBundle: Sendable {
    public let asset: ModelAsset
    public let bytes: Data
}

/// 模拟“随 App 安装落盘”的自带模型资产。
/// 真实实现替换为 App Bundle / On-Demand Resources 读取，接口不变。
public struct BundledAssetCatalog: Sendable {
    var bundles: [ModelTier: BundledAssetBundle] = [:]

    public init(version: String = "1.0.0") throws {
        for tier in ModelTier.allCases {
            bundles[tier] = try Self.simulateBundle(tier: tier, version: version)
        }
    }

    public func bundle(for tier: ModelTier) -> BundledAssetBundle? { bundles[tier] }

    public func list() -> [ModelAsset] {
        ModelTier.allCases.compactMap { bundles[$0]?.asset }
    }

    /// 与 JS `createSimulatedModelBundle` 对齐：确定性字节 + 真实 SHA-256。
    public static func simulateBundle(tier: ModelTier, version: String, corrupt: Bool = false) throws -> BundledAssetBundle {
        let sizes: [ModelTier: Int] = [
            .flagship: 2_250_000_000,
            .mainstream: 1_250_000_000,
            .entry: 800_000_000,
        ]
        var bytes = Data("edge-assistant:simulated-model:\(tier.rawValue):\(version)".utf8)
        let sha256 = SHA256Verifier.hexDigest(of: bytes)
        if corrupt { bytes[0] ^= 0xff }
        let asset = ModelAsset(
            id: "\(tier.rawValue)-simulated-\(version)",
            tier: tier,
            version: version,
            sha256: sha256,
            sizeBytes: sizes[tier] ?? 0,
            capabilities: tier.supportedModes
        )
        return BundledAssetBundle(asset: asset, bytes: bytes)
    }
}

// MARK: - 自动装载编排器（安装即内置，启动即执行）

public enum AutoInstallStage: String, Sendable {
    case storageCheck, verify, activate
}

public struct AutoInstallProgress: Sendable {
    public let stage: AutoInstallStage
    public let tier: ModelTier
    public let isOK: Bool
    public let assetID: String?
    public let reason: String?
}

public struct AutoInstallResult: Sendable {
    public let isOK: Bool
    public let asset: ModelAsset?
    public let reason: String?
    public let requiredBytes: Int?
    public let availableBytes: Int?
    public let status: AssetManagerStatus
}

/// 启动序列：存储检查（防御性，默认视为充足）→ SHA-256 校验 → 激活。
/// 任一步失败不改变已激活资产。对应 JS `createAutoInstaller`。
public struct AutoInstaller: Sendable {
    private let catalog: BundledAssetCatalog
    private let manager: ModelAssetManager
    private let onProgress: @Sendable (AutoInstallProgress) -> Void
    private let freeBytes: (() -> Int)?

    public init(
        catalog: BundledAssetCatalog,
        manager: ModelAssetManager,
        onProgress: @escaping @Sendable (AutoInstallProgress) -> Void = { _ in },
        freeBytes: (() -> Int)? = nil
    ) {
        self.catalog = catalog
        self.manager = manager
        self.onProgress = onProgress
        self.freeBytes = freeBytes
    }

    public func installForTier(_ tier: ModelTier) async -> AutoInstallResult {
        guard let bundle = catalog.bundle(for: tier) else {
            onProgress(AutoInstallProgress(stage: .storageCheck, tier: tier, isOK: false, assetID: nil, reason: "no bundled asset"))
            return AutoInstallResult(isOK: false, asset: nil, reason: "no bundled asset for tier", requiredBytes: nil, availableBytes: nil, status: await manager.status())
        }

        if let freeBytes = freeBytes {
            let available = freeBytes()
            if available < bundle.asset.sizeBytes {
                onProgress(AutoInstallProgress(stage: .storageCheck, tier: tier, isOK: false, assetID: nil, reason: "insufficient-storage"))
                return AutoInstallResult(
                    isOK: false, asset: nil, reason: "insufficient-storage",
                    requiredBytes: bundle.asset.sizeBytes, availableBytes: available,
                    status: await manager.status()
                )
            }
        }
        onProgress(AutoInstallProgress(stage: .storageCheck, tier: tier, isOK: true, assetID: bundle.asset.id, reason: nil))

        onProgress(AutoInstallProgress(stage: .verify, tier: tier, isOK: true, assetID: bundle.asset.id, reason: nil))
        let result = await manager.install(bundle.asset, bytes: bundle.bytes)

        guard result.isOK else {
            onProgress(AutoInstallProgress(stage: .activate, tier: tier, isOK: false, assetID: bundle.asset.id, reason: result.reason))
            return AutoInstallResult(
                isOK: false, asset: nil, reason: result.reason,
                requiredBytes: nil, availableBytes: nil, status: result.status
            )
        }

        onProgress(AutoInstallProgress(stage: .activate, tier: tier, isOK: true, assetID: bundle.asset.id, reason: nil))
        return AutoInstallResult(isOK: true, asset: bundle.asset, reason: nil, requiredBytes: nil, availableBytes: nil, status: result.status)
    }
}
