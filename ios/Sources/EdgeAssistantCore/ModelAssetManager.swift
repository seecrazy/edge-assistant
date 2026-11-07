import Foundation

public struct AssetManagerStatus: Equatable, Sendable {
    public let activeAsset: ModelAsset?
    public let rollbackAsset: ModelAsset?
    public let rollbackAssetID: String?
    public let lastError: String?
    public let installCount: Int
}

public struct InstallResult: Equatable, Sendable {
    public let isOK: Bool
    public let previousAssetID: String?
    public let reason: String?
    public let expectedSHA256: String?
    public let actualSHA256: String?
    public let status: AssetManagerStatus
}

public struct RollbackResult: Equatable, Sendable {
    public let isOK: Bool
    public let reason: String?
    public let status: AssetManagerStatus
}

/// 安装保护与单步回滚，与 JS `createModelAssetManager` 对齐。
/// 校验失败不替换已激活资产；成功安装保留单步回滚。
public actor ModelAssetManager {
    private var activeAsset: ModelAsset?
    private var rollbackAsset: ModelAsset?
    private var lastError: String?
    private var installCount = 0
    private let verify: (ModelAsset, Data) -> AssetVerification

    public init(verify: @escaping (ModelAsset, Data) -> AssetVerification = SHA256Verifier.verify(asset:bytes:)) {
        self.verify = verify
    }

    public func status() -> AssetManagerStatus {
        AssetManagerStatus(
            activeAsset: activeAsset,
            rollbackAsset: rollbackAsset,
            rollbackAssetID: rollbackAsset?.id,
            lastError: lastError,
            installCount: installCount
        )
    }

    public func install(_ asset: ModelAsset, bytes: Data) -> InstallResult {
        let result = verify(asset, bytes)
        installCount += 1

        guard result.isValid else {
            lastError = result.reason ?? "asset verification failed"
            return InstallResult(
                isOK: false,
                previousAssetID: nil,
                reason: lastError,
                expectedSHA256: result.expectedSHA256,
                actualSHA256: result.actualSHA256,
                status: status()
            )
        }

        let previous = activeAsset
        activeAsset = asset
        rollbackAsset = previous
        lastError = nil
        return InstallResult(
            isOK: true,
            previousAssetID: previous?.id,
            reason: nil,
            expectedSHA256: nil,
            actualSHA256: nil,
            status: status()
        )
    }

    public func rollback() -> RollbackResult {
        guard let previous = rollbackAsset else {
            return RollbackResult(isOK: false, reason: "no rollback asset available", status: status())
        }
        activeAsset = previous
        rollbackAsset = nil
        lastError = nil
        return RollbackResult(isOK: true, reason: nil, status: status())
    }
}
