import XCTest
import CryptoKit
@testable import EdgeAssistantCore

final class ModelStoreTests: XCTestCase {
    /// 测试用本地传输：模拟分块复制并上报进度。
    private struct LocalFileFetcher: ModelFileFetching {
        func fetch(
            from url: URL,
            to destination: URL,
            expectedBytes: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let data = try Data(contentsOf: url)
            progress(0.5)
            try data.write(to: destination, options: .atomic)
            progress(1)
        }
    }

    /// 主源（huggingface.co）抛错、镜像（hf-mirror.com）成功的传输模拟。
    private struct MirrorFallbackFetcher: ModelFileFetching {
        func fetch(
            from url: URL,
            to destination: URL,
            expectedBytes: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            if url.host == "huggingface.co" {
                throw URLError(.cannotConnectToHost)
            }
            try Data("mirror-content".utf8).write(to: destination, options: .atomic)
            progress(1)
        }
    }

    private var tempDir: URL!
    private var sourceDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-tests-\(UUID().uuidString)", isDirectory: true)
        sourceDir = tempDir.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSourceFile(name: String, content: String) throws -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private struct PathAwareJSONFetcher: ModelFileFetching {
        let badURL: URL
        let goodURL: URL

        func fetch(
            from url: URL,
            to destination: URL,
            expectedBytes: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            if url == badURL {
                try Data("<html>failed</html>".utf8).write(to: destination)
                throw URLError(.cannotConnectToHost)
            }
            try Data("{\"ok\":true}".utf8).write(to: destination)
            progress(1)
        }
    }

    private struct CancellableAfterConfigFetcher: ModelFileFetching {
        func fetch(
            from url: URL,
            to destination: URL,
            expectedBytes: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
            progress(1)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private final class CountingFetcher: ModelFileFetching, @unchecked Sendable {
        private let inner: any ModelFileFetching
        private let lock = NSLock()
        private var urls: [URL] = []

        init(inner: any ModelFileFetching) {
            self.inner = inner
        }

        var fetchedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }

        func fetch(
            from url: URL,
            to destination: URL,
            expectedBytes: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            lock.lock()
            urls.append(url)
            lock.unlock()
            try await inner.fetch(
                from: url,
                to: destination,
                expectedBytes: expectedBytes,
                progress: progress
            )
        }
    }

    private func makeModel(id: String, files: [RemoteModelFile]) -> OpenSourceModel {
        makeModel(id: id, files: files, mirrorBase: nil)
    }

    private func makeModel(id: String, files: [RemoteModelFile], mirrorBase: String?) -> OpenSourceModel {
        OpenSourceModel(
            id: id, displayName: "Test Model", source: "test/repo",
            format: "mlx-4bit", parameters: "0.5B", sizeBytes: 1024,
            license: "Apache-2.0", minTier: .entry, capabilities: [.chat], files: files,
            mirrorBase: mirrorBase
        )
    }

    func testDownloadInstallActivateDeleteLifecycle() async throws {
        let a = try makeSourceFile(name: "a.json", content: #"{"model":"qwen"}"#)
        let tokenizer = try makeSourceFile(name: "tokenizer.json", content: #"{"model":"tokenizer"}"#)
        let weightSource = sourceDir.appendingPathComponent("model.safetensors")
        let weightHeader = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,1]}}"#.utf8)
        try (withUnsafeBytes(of: UInt64(weightHeader.count).littleEndian) { Data($0) } + weightHeader + Data([1]))
            .write(to: weightSource)
        let model = makeModel(id: "test-model", files: [
            RemoteModelFile(path: "config.json", url: a),
            RemoteModelFile(path: "tokenizer.json", url: tokenizer),
            RemoteModelFile(path: "model.safetensors", url: weightSource),
        ])

        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: LocalFileFetcher())
        var fractions: [Double] = []
        let installed = try await store.download(model) { _, fraction in fractions.append(fraction) }

        XCTAssertEqual(installed.id, "test-model")
        XCTAssertEqual(fractions, [0.5, 1, 0.5, 1, 0.5, 1])
        let isInstalledNow = await store.isInstalled("test-model")
        XCTAssertTrue(isInstalledNow)

        // 幂等：重复下载返回已安装快照
        let again = try await store.download(model)
        XCTAssertEqual(again.aggregateSHA256, installed.aggregateSHA256)

        // 激活 → ModelAsset 能力与聚合摘要一致
        let asset = try await store.activate("test-model")
        XCTAssertEqual(asset.capabilities, [.chat])
        XCTAssertEqual(asset.sizeBytes, 1024)
        XCTAssertEqual(asset.sha256.count, 64)
        XCTAssertEqual(asset.format, "mlx-4bit")
        XCTAssertEqual(asset.localDirectory?.lastPathComponent, "test-model")

        // 删除 → notInstalled
        try await store.delete("test-model", activeModelID: nil)
        let goneAfterDelete = await store.isInstalled("test-model")
        XCTAssertFalse(goneAfterDelete)
        await XCTAssertThrowsErrorAsync(try await store.activate("test-model"))
    }

    func testChecksumMismatchCleansUpDirectory() async throws {
        let file = try makeSourceFile(name: "bad.bin", content: "corrupt-content")
        let model = makeModel(id: "bad-model", files: [
            RemoteModelFile(path: "weights.bin", url: file, sha256: String(repeating: "0", count: 64)),
        ])

        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: LocalFileFetcher())
        await XCTAssertThrowsErrorAsync(try await store.download(model))
        let badInstalled = await store.isInstalled("bad-model")
        XCTAssertFalse(badInstalled)
    }

    func testInvalidJSONDownloadIsRejectedAndCleansUp() async throws {
        let config = try makeSourceFile(name: "bad-config.json", content: "<html>rate limited</html>")
        let weights = try makeSourceFile(name: "unused.bin", content: "unused")
        let model = makeModel(id: "invalid-json", files: [
            RemoteModelFile(path: "config.json", url: config),
            RemoteModelFile(path: "weights.bin", url: weights),
        ])

        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: LocalFileFetcher())
        await XCTAssertThrowsErrorAsync(try await store.download(model))
        let installed = await store.isInstalled("invalid-json")
        XCTAssertFalse(installed)
    }

    func testInvalidPrimaryFallsBackToValidMirror() async throws {
        let bad = try makeSourceFile(name: "bad-config.json", content: "<html>failed</html>")
        let good = try makeSourceFile(name: "good-config.json", content: #"{"ok":true}"#)
        let model = makeModel(id: "json-mirror", files: [
            RemoteModelFile(path: "config.json", url: bad),
        ], mirrorBase: good.deletingLastPathComponent().appendingPathComponent("/").absoluteString)

        let store = ModelStoreManager(
            baseDirectory: tempDir.appendingPathComponent("store"),
            fetcher: PathAwareJSONFetcher(badURL: bad, goodURL: good)
        )
        _ = try await store.download(model)
        let installed = await store.isInstalled("json-mirror")
        XCTAssertTrue(installed)
    }

    func testDeleteRejectsActiveModel() async throws {
        let file = try makeSourceFile(name: "m.bin", content: "weights")
        let model = makeModel(id: "active-model", files: [RemoteModelFile(path: "m.bin", url: file)])
        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: LocalFileFetcher())
        _ = try await store.download(model)

        await XCTAssertThrowsErrorAsync(try await store.delete("active-model", activeModelID: "active-model"))
        let stillInstalled = await store.isInstalled("active-model")
        XCTAssertTrue(stillInstalled)
    }

    func testDefaultCatalogIsWellFormed() {
        let catalog = OpenSourceModelCatalog.defaultCatalog()
        XCTAssertGreaterThanOrEqual(catalog.count, 4)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertTrue(catalog.contains { $0.compatibility == .supported && $0.modelType == "gemma4" })
        XCTAssertTrue(catalog.contains { $0.compatibility == .unsupported && $0.modelType == "minicpmv4_7" })
        XCTAssertTrue(catalog.contains { $0.compatibility == .requiresConversion && $0.source == "taobao-mnn/MNN-Pocket-0.3B" })
        for model in catalog {
            let isPinnedCompatibilityEntry = model.compatibility != nil
            XCTAssertTrue(model.capabilities.contains(.chat) || isPinnedCompatibilityEntry)
            XCTAssertGreaterThan(model.sizeBytes, 0)
            let usesOnlineManifest = model.requiresOnlineManifest == true
                || model.compatibility == .unsupported
                || model.compatibility == .requiresConversion
            XCTAssertTrue(model.files.contains { $0.path.contains("safetensors") } || usesOnlineManifest)
            for file in model.files {
                XCTAssertEqual(file.url.scheme, "https")
            }
        }
    }

    func testRepairOldInstallWhenNewManifestRequiresMissingTemplate() async throws {
        let config = try makeSourceFile(name: "repair-config.json", content: #"{"model":"qwen"}"#)
        let tokenizer = try makeSourceFile(name: "repair-tokenizer.json", content: #"{"ok":true}"#)
        let template = try makeSourceFile(name: "repair-chat-template.jinja", content: "template")
        let weight = sourceDir.appendingPathComponent("repair-model.safetensors")
        let weightHeader = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,1]}}"#.utf8)
        try (withUnsafeBytes(of: UInt64(weightHeader.count).littleEndian) { Data($0) }
             + weightHeader + Data([1])).write(to: weight)

        let oldFiles = [
            RemoteModelFile(path: "config.json", url: config),
            RemoteModelFile(path: "tokenizer.json", url: tokenizer),
            RemoteModelFile(path: "model.safetensors", url: weight),
        ]
        let newFiles = oldFiles + [
            RemoteModelFile(path: "chat_template.jinja", url: template),
        ]
        let oldModel = makeModel(id: "repair-model", files: oldFiles)
        let newModel = makeModel(id: "repair-model", files: newFiles)

        let fetcher = CountingFetcher(inner: LocalFileFetcher())
        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: fetcher)
        _ = try await store.download(oldModel)
        _ = try await store.download(newModel)

        let modelDir = tempDir
            .appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("repair-model", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("chat_template.jinja").path))
        XCTAssertTrue(fetcher.fetchedURLs.contains(template))
        let repaired = await store.isInstalled("repair-model")
        XCTAssertTrue(repaired)
    }

    func testMirrorFallbackWhenPrimaryUnreachable() async throws {
        let file = try makeSourceFile(name: "unused.bin", content: "unused")
        let model = OpenSourceModel(
            id: "mirror-model", displayName: "Mirror Test", source: "test/repo",
            format: "mlx-4bit", parameters: "0.5B", sizeBytes: 1024,
            license: "Apache-2.0", minTier: .entry, capabilities: [.chat],
            files: [RemoteModelFile(path: "weights.bin", url: file)],
            mirrorBase: "https://hf-mirror.com/test/repo/resolve/main/"
        )

        let store = ModelStoreManager(baseDirectory: tempDir.appendingPathComponent("store"), fetcher: MirrorFallbackFetcher())
        let installed = try await store.download(model)
        XCTAssertEqual(installed.id, "mirror-model")
        let ok = await store.isInstalled("mirror-model")
        XCTAssertTrue(ok)
    }

    func testCancellationKeepsCompletedFileAndResumeSkipsIt() async throws {
        let config = try makeSourceFile(name: "config.json", content: #"{"model":"qwen"}"#)
        let weight = sourceDir.appendingPathComponent("model.safetensors")
        let weightHeader = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,1]}}"#.utf8)
        try (withUnsafeBytes(of: UInt64(weightHeader.count).littleEndian) { Data($0) }
             + weightHeader + Data([1])).write(to: weight)
        let model = makeModel(id: "resumable-model", files: [
            RemoteModelFile(path: "config.json", url: config),
            RemoteModelFile(path: "model.safetensors", url: weight),
        ])
        let storeDir = tempDir.appendingPathComponent("store", isDirectory: true)
        let cancellingStore = ModelStoreManager(
            baseDirectory: storeDir,
            fetcher: CancellableAfterConfigFetcher()
        )
        let task = Task { try await cancellingStore.download(model) }

        let configDestination = storeDir
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent("resumable-model", isDirectory: true)
            .appendingPathComponent("config.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: configDestination.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: configDestination.path))
        task.cancel()
        try? await task.value

        let installedAfterCancel = await cancellingStore.isInstalled("resumable-model")
        XCTAssertFalse(installedAfterCancel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configDestination.path))

        let resumeFetcher = CountingFetcher(inner: LocalFileFetcher())
        let resumeStore = ModelStoreManager(baseDirectory: storeDir, fetcher: resumeFetcher)
        let installed = try await resumeStore.download(model)
        XCTAssertEqual(installed.id, "resumable-model")
        XCTAssertFalse(resumeFetcher.fetchedURLs.contains(config))
        let installedNow = await resumeStore.isInstalled("resumable-model")
        XCTAssertTrue(installedNow)
    }

    func testResidualInstallIsListedCleanableAndSafeToRedownload() async throws {
        let storeDir = tempDir.appendingPathComponent("store", isDirectory: true)
        let residual = storeDir
            .appendingPathComponent("residual-model", isDirectory: true)
        try FileManager.default.createDirectory(at: residual, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: residual.appendingPathComponent("config.json"))
        let staged = storeDir
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent("staged-model", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staged.appendingPathComponent("weights.bin"))
        let corruptMetadata = storeDir
            .appendingPathComponent("corrupt-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptMetadata, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: corruptMetadata.appendingPathComponent("config.json"))
        try Data("<bad-json>".utf8).write(to: corruptMetadata.appendingPathComponent("metadata.json"))

        let store = ModelStoreManager(baseDirectory: storeDir, fetcher: LocalFileFetcher())
        let health = await store.installHealth("residual-model")
        XCTAssertEqual(health, .residual)
        let residualIDs = await store.residualInstallIDs()
        XCTAssertEqual(residualIDs, ["corrupt-metadata", "residual-model", "staged-model"])

        try await store.cleanupResidualInstall("residual-model")
        try await store.cleanupResidualInstall("staged-model")
        try await store.cleanupResidualInstall("corrupt-metadata")
        let healthAfterCleanup = await store.installHealth("residual-model")
        XCTAssertEqual(healthAfterCleanup, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let residualIDsAfterCleanup = await store.residualInstallIDs()
        XCTAssertTrue(residualIDsAfterCleanup.isEmpty)
    }
}
