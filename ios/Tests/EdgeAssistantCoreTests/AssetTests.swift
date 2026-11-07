import XCTest
@testable import EdgeAssistantCore

final class AssetTests: XCTestCase {
    private func baseAsset(
        id: String = "flagship-1.0.0",
        tier: ModelTier = .flagship,
        version: String = "1.0.0",
        sha256: String = String(repeating: "a", count: 64),
        capabilities: [CapabilityMode] = [.chat, .voice, .video]
    ) -> ModelAsset {
        ModelAsset(id: id, tier: tier, version: version, sha256: sha256, sizeBytes: 1, capabilities: capabilities)
    }

    /// 线程安全的进度收集器，避免 @Sendable 闭包捕获可变局部变量。
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AutoInstallProgress] = []
        var all: [AutoInstallProgress] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
        func append(_ item: AutoInstallProgress) {
            lock.lock(); items.append(item); lock.unlock()
        }
    }

    func testValidatesRequiredMetadata() {
        XCTAssertTrue(ModelAssetValidator.validate(baseAsset()).isValid)

        let invalid = ModelAssetValidator.validate(
            ModelAsset(id: "invalid", tier: .flagship, version: "1.0", sha256: "bad", sizeBytes: -1, capabilities: [])
        )
        XCTAssertFalse(invalid.isValid)
        XCTAssertTrue(invalid.errors.contains { $0.contains("version") })
        XCTAssertTrue(invalid.errors.contains { $0.contains("sha256") })
        XCTAssertTrue(invalid.errors.contains { $0.contains("sizeBytes") })
        XCTAssertTrue(invalid.errors.contains { $0.contains("capabilities") })
    }

    func testVerifiesBundledBytesBySHA256() throws {
        let bundle = try BundledAssetCatalog.simulateBundle(tier: .flagship, version: "1.0.0")
        XCTAssertTrue(SHA256Verifier.verify(asset: bundle.asset, bytes: bundle.bytes).isValid)

        var corruptBytes = bundle.bytes
        corruptBytes[0] ^= 0xff
        let invalid = SHA256Verifier.verify(asset: bundle.asset, bytes: corruptBytes)
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.reason, "sha256 mismatch")
    }

    func testRegistrySelectsLatestAssetForTier() throws {
        var registry = ModelRegistry()
        try registry.register(baseAsset(id: "a", version: "1.0.0", sha256: String(repeating: "b", count: 64)))
        try registry.register(baseAsset(id: "b", version: "1.2.0", sha256: String(repeating: "c", count: 64)))
        try registry.register(baseAsset(
            id: "entry", tier: .entry, version: "0.9.0",
            sha256: String(repeating: "d", count: 64),
            capabilities: [.chat, .voice]
        ))

        XCTAssertEqual(registry.latest(for: .flagship)?.id, "b")
        XCTAssertEqual(registry.resolve(for: .entry).modes, [.chat, .voice])
        XCTAssertNil(registry.resolve(for: .mainstream).asset)
    }

    func testManagerKeepsActiveModelOnFailedInstall() async throws {
        let manager = ModelAssetManager()
        let good = try BundledAssetCatalog.simulateBundle(tier: .mainstream, version: "1.0.0")
        let installed = await manager.install(good.asset, bytes: good.bytes)
        XCTAssertTrue(installed.isOK)

        let corrupt = try BundledAssetCatalog.simulateBundle(tier: .mainstream, version: "1.1.0", corrupt: true)
        let failed = await manager.install(corrupt.asset, bytes: corrupt.bytes)
        XCTAssertFalse(failed.isOK)
        XCTAssertEqual(failed.reason, "sha256 mismatch")
        let failedStatus = await manager.status()
        XCTAssertEqual(failedStatus.activeAsset?.id, "mainstream-simulated-1.0.0")
    }

    func testManagerRollsBackSingleStep() async throws {
        let manager = ModelAssetManager()
        let first = try BundledAssetCatalog.simulateBundle(tier: .entry, version: "1.0.0")
        let second = try BundledAssetCatalog.simulateBundle(tier: .entry, version: "1.1.0")

        _ = await manager.install(first.asset, bytes: first.bytes)
        _ = await manager.install(second.asset, bytes: second.bytes)
        var status = await manager.status()
        XCTAssertEqual(status.activeAsset?.version, "1.1.0")
        XCTAssertEqual(status.rollbackAssetID, "entry-simulated-1.0.0")

        let rollback = await manager.rollback()
        XCTAssertTrue(rollback.isOK)
        status = await manager.status()
        XCTAssertEqual(status.activeAsset?.version, "1.0.0")
        XCTAssertNil(status.rollbackAssetID)

        let noRollback = await manager.rollback()
        XCTAssertFalse(noRollback.isOK)
        XCTAssertEqual(noRollback.reason, "no rollback asset available")
    }

    func testAutoInstallerSuccessActivatesBundledAsset() async throws {
        let catalog = try BundledAssetCatalog()
        let manager = ModelAssetManager()
        let collector = ProgressCollector()
        let installer = AutoInstaller(catalog: catalog, manager: manager) { collector.append($0) }

        let result = await installer.installForTier(.mainstream)
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(result.asset?.tier, .mainstream)
        let status2 = await manager.status()
        XCTAssertEqual(status2.activeAsset?.id, result.asset?.id)
        XCTAssertEqual(collector.all.map(\.stage), [.storageCheck, .verify, .activate])
    }

    func testAutoInstallerCorruptAssetDoesNotReplaceActive() async throws {
        let catalog = try BundledAssetCatalog()
        let manager = ModelAssetManager()
        let good = try BundledAssetCatalog.simulateBundle(tier: .entry, version: "1.0.0")
        _ = await manager.install(good.asset, bytes: good.bytes)

        let original = try BundledAssetCatalog.simulateBundle(tier: .entry, version: "1.0.0")
        let corruptBytes: Data = {
            var b = original.bytes
            b[0] ^= 0xff
            return b
        }()

        let corrupt = BundledAssetBundle(asset: original.asset, bytes: corruptBytes)
        var catalogWithCorrupt = try BundledAssetCatalog()
        catalogWithCorrupt.bundles[.entry] = corrupt
        let installer = AutoInstaller(catalog: catalogWithCorrupt, manager: manager)

        let result = await installer.installForTier(.entry)
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.reason, "sha256 mismatch")
        let status3 = await manager.status()
        XCTAssertEqual(status3.activeAsset?.id, good.asset.id)
    }

    func testAutoInstallerFailsBeforeVerifyOnInsufficientStorage() async throws {
        let catalog = try BundledAssetCatalog()
        let manager = ModelAssetManager()
        let collector2 = ProgressCollector()
        let installer = AutoInstaller(
            catalog: catalog,
            manager: manager,
            onProgress: { collector2.append($0) },
            freeBytes: { 1024 }
        )

        let result = await installer.installForTier(.flagship)
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.reason, "insufficient-storage")
        XCTAssertGreaterThan(result.requiredBytes ?? 0, result.availableBytes ?? 0)
        let status4 = await manager.status()
        XCTAssertNil(status4.activeAsset)
        XCTAssertEqual(collector2.all.map(\.stage), [.storageCheck])
        XCTAssertEqual(collector2.all.first?.isOK, false)
    }
}
