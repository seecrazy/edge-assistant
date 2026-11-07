import Foundation
import CryptoKit

// MARK: - 目录元数据（ADR 0005）

public struct RemoteModelFile: Codable, Equatable, Sendable {
    public let path: String
    public let url: URL
    public let sizeBytes: Int64?
    public let sha256: String?

    public init(path: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil) {
        self.path = path
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct OpenSourceModel: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let source: String
    public let format: String
    public let parameters: String
    public let sizeBytes: Int64
    public let license: String
    public let minTier: ModelTier
    public let capabilities: [CapabilityMode]
    public let files: [RemoteModelFile]
    public let modelType: String?
    public let compatibility: ModelCompatibility?
    public let compatibilityReason: String?
    public let requiresOnlineManifest: Bool?
    /// 主源不可达时的镜像目录前缀（ADR 0005：镜像回退）。
    public let mirrorBase: String?

    public init(
        id: String, displayName: String, source: String, format: String,
        parameters: String, sizeBytes: Int64, license: String,
        minTier: ModelTier, capabilities: [CapabilityMode], files: [RemoteModelFile],
        mirrorBase: String? = nil,
        modelType: String? = nil,
        compatibility: ModelCompatibility? = nil,
        compatibilityReason: String? = nil,
        requiresOnlineManifest: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.format = format
        self.parameters = parameters
        self.sizeBytes = sizeBytes
        self.license = license
        self.minTier = minTier
        self.capabilities = capabilities
        self.files = files
        self.mirrorBase = mirrorBase
        self.modelType = modelType
        self.compatibility = compatibility
        self.compatibilityReason = compatibilityReason
        self.requiresOnlineManifest = requiresOnlineManifest
    }
}

public struct InstalledModel: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let model: OpenSourceModel
    public let installedAt: Date
    public let aggregateSHA256: String
}

public enum InstallHealth: Equatable, Sendable {
    case missing
    case installed
    case incomplete
    case residual
}

public enum ModelStoreError: Error, Equatable {
    case notInstalled
    case modelIsActive
    case compatibilityBlocked(String)
    case manifestUnavailable(String)
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case invalidModelFile(String, String)
}

extension ModelStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "模型尚未安装。"
        case .modelIsActive:
            return "模型正在使用中，请先切换到其他模型。"
        case .compatibilityBlocked(let reason):
            return "当前 App 不支持该模型：\(reason)"
        case .manifestUnavailable(let repository):
            return "无法读取模型文件清单：\(repository)"
        case .insufficientStorage(let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "存储空间不足：预计需要 \(formatter.string(fromByteCount: requiredBytes))，当前可用 \(formatter.string(fromByteCount: availableBytes))。"
        case .checksumMismatch(let path):
            return "模型文件校验失败：\(path) 的 SHA-256 不匹配。请删除模型后重新下载。"
        case .sizeMismatch(let path):
            return "模型文件不完整：\(path) 的大小与清单不一致。请删除模型后重新下载。"
        case .invalidModelFile(let path, let reason):
            return "模型文件损坏或不受支持：\(path)（\(reason)）。请删除模型后重新下载。"
        }
    }
}

// MARK: - 文件传输抽象（真实 URLSession / 测试本地注入）

public protocol ModelFileFetching: Sendable {
    func fetch(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// 流式下载：AsyncBytes → 256KB 缓冲写盘，支持取消与进度。
public struct URLSessionModelDownloader: ModelFileFetching {
    private let session: URLSession

    public init() {
        self.session = URLSessionModelDownloader.defaultSession()
    }

    public init(session: URLSession) {
        self.session = session
    }

    /// 大文件下载不应被连接空闲等待拖死；请求与资源超时都按 7 天保护完整权重下载。
    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 7 * 24 * 60 * 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func fetch(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let (stream, continuation) = AsyncThrowingStream<DownloadEvent, Error>.makeStream()
        let delegate = DownloadDelegate(continuation: continuation, destination: destination)
        let task = session.downloadTask(with: url)
        task.delegate = delegate
        continuation.onTermination = { _ in
            task.cancel()
        }
        task.resume()

        var receivedBytes: Int64 = 0
        var expected = expectedBytes ?? 0
        var lastReportedBytes: Int64 = -1

        for try await event in stream {
            switch event {
            case let .progress(received, totalBytes):
                receivedBytes = received
                if totalBytes > 0 {
                    expected = totalBytes
                }
                // 下载代理每几十 KB 就回调一次；只在 256KB 边界上报，避免 UI 和 actor 被刷爆。
                if receivedBytes - lastReportedBytes >= 262_144 {
                    if expected > 0 {
                        progress(min(Double(receivedBytes) / Double(expected), 0.999))
                    }
                    lastReportedBytes = receivedBytes
                }
            case .finished:
                break
            case let .failure(error):
                throw error
            }
        }

        progress(1)
    }
}

private enum DownloadEvent: @unchecked Sendable {
    case progress(received: Int64, total: Int64)
    case finished(URL)
    case failure(Error)
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    private let destination: URL

    init(
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation,
        destination: URL
    ) {
        self.continuation = continuation
        self.destination = destination
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(.progress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation.yield(.finished(destination))
        } catch {
            continuation.yield(.failure(error))
        }
        continuation.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.yield(.failure(error))
        }
        continuation.finish()
    }
}

// MARK: - 模型商店管理器

public actor ModelStoreManager {
    private let baseURL: URL
    private let fetcher: any ModelFileFetching
    private let manifestProvider: (any RemoteModelManifestProviding)?
    private let now: @Sendable () -> Date

    public init(
        baseDirectory: URL,
        fetcher: any ModelFileFetching = URLSessionModelDownloader(),
        manifestProvider: (any RemoteModelManifestProviding)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseDirectory
        self.fetcher = fetcher
        self.manifestProvider = manifestProvider
        self.now = now
    }

    private func modelDirectory(_ id: String) -> URL {
        baseURL.appendingPathComponent(id, isDirectory: true)
    }

    private func metadataURL(_ id: String) -> URL {
        modelDirectory(id).appendingPathComponent("metadata.json")
    }

    private func stagingDirectory(_ id: String) -> URL {
        baseURL.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// 聚合摘要：对排序后的 "path:sha256\n" 行再取 SHA-256。
    public static func aggregateDigest(_ files: [(path: String, sha256: String)]) -> String {
        let lines = files
            .sorted { $0.path < $1.path }
            .map { "\($0.path):\($0.sha256)\n" }
            .joined()
        let digest = SHA256.hash(data: Data(lines.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func listInstalled() -> [InstalledModel] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entries = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { dir in
            let metadata = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadata),
                  let installed = try? decoder.decode(InstalledModel.self, from: data) else {
                return nil
            }
            return installed
        }
        .sorted { $0.installedAt < $1.installedAt }
    }

    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(id).path)
    }

    public func installHealth(_ id: String) -> InstallHealth {
        let directory = modelDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return .missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? Data(contentsOf: metadataURL(id)),
              (try? decoder.decode(InstalledModel.self, from: metadata)) != nil else {
            return .residual
        }
        do {
            try RemoteFileValidator.validateModelDirectory(at: directory)
            return .installed
        } catch {
            return .incomplete
        }
    }

    public func residualInstallIDs() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let finalResiduals = entries
            .filter { $0.lastPathComponent != ".staging" }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && installHealth(url.lastPathComponent) == .residual
            }
            .map(\.lastPathComponent)
        let stagedEntries = (try? FileManager.default.contentsOfDirectory(
            at: baseURL.appendingPathComponent(".staging", isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let stagedResiduals = stagedEntries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
        return Array(Set(finalResiduals + stagedResiduals)).sorted()
    }

    /// 清理无 metadata 的最终残留和中断 staging；完整安装本体保持受保护。
    public func cleanupResidualInstall(_ id: String) throws {
        let health = installHealth(id)
        let staging = stagingDirectory(id)
        let hasStaging = FileManager.default.fileExists(atPath: staging.path)
        guard health == .residual || hasStaging else { throw ModelStoreError.notInstalled }
        if health == .residual {
            try FileManager.default.removeItem(at: modelDirectory(id))
        }
        try? FileManager.default.removeItem(at: stagingDirectory(id))
    }

    /// 下载 → 结构校验 → 大小/SHA 校验 → 原子安装；取消/失败保留 staging 供幂等续传。
    @discardableResult
    public func download(
        _ model: OpenSourceModel,
        progress: @escaping @Sendable (_ fileIndex: Int, _ fileFraction: Double) -> Void = { _, _ in }
    ) async throws -> InstalledModel {
        if let existing = listInstalled().first(where: { $0.id == model.id }) {
            if model.files.isEmpty {
                if (try? RemoteFileValidator.validateModelDirectory(at: modelDirectory(model.id))) != nil {
                    return existing
                }
            } else {
                if try await Self.hasVerifiedExpectedFiles(model.files, in: modelDirectory(model.id)) {
                    return existing
                }
            }
            // 不完整安装保留到 staging 成功后原子替换，避免下载中途丢失旧目录。
        }

        let dir = modelDirectory(model.id)
        let staging = stagingDirectory(model.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            if model.compatibility == .unsupported {
                throw ModelStoreError.compatibilityBlocked(model.compatibilityReason ?? "当前 App 不支持该架构。")
            }
            if model.compatibility == .requiresConversion {
                throw ModelStoreError.compatibilityBlocked(model.compatibilityReason ?? "该模型需要 MLX 转换。")
            }

            var files = model.files
            if model.requiresOnlineManifest == true || files.isEmpty {
                files = try await manifestProvider?.files(
                    repositoryID: model.source,
                    mirrorBase: model.mirrorBase
                ) ?? []
                guard !files.isEmpty else { throw ModelStoreError.manifestUnavailable(model.source) }
            }

            let manifestBytes = files.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
            let requiredBytes = max(manifestBytes, model.sizeBytes) + 1_000_000_000
            let availableBytes = Self.availableVolumeBytes(at: baseURL)
            if let availableBytes, availableBytes < requiredBytes {
                throw ModelStoreError.insufficientStorage(
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            }

            var digests: [(path: String, sha256: String)] = []
            for (index, file) in files.enumerated() {
                let destination = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let digest = try await materialize(
                    file,
                    to: destination,
                    mirrorBase: model.mirrorBase,
                    progress: { progress(index, $0) }
                )
                digests.append((file.path, digest))
            }

            let installed = InstalledModel(
                id: model.id,
                model: model,
                installedAt: now(),
                aggregateSHA256: Self.aggregateDigest(digests)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(installed).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            try FileManager.default.moveItem(at: staging, to: dir)
            return installed
        } catch is CancellationError {
            // staging 保留完整文件，下一次下载可通过大小/结构/摘要校验复用。
            throw CancellationError()
        } catch {
            // 网络/校验中断保留 staging；下一次 validExistingFileDigest 会复用完整文件并覆盖坏文件。
            throw error
        }
    }

    /// 主源下载并完成全部校验；结构/大小/摘要损坏也允许镜像重试（ADR 0010）。
    private func materialize(
        _ file: RemoteModelFile,
        to destination: URL,
        mirrorBase: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        if let existingDigest = try? await Self.validExistingFileDigest(file: file, at: destination) {
            return existingDigest
        }
        do {
            try await fetcher.fetch(
                from: file.url,
                to: destination,
                expectedBytes: file.sizeBytes,
                progress: progress
            )
            return try await verifyDownloaded(file: file, at: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let mirrorBase else { throw error }
            let mirrorURL = URL(string: mirrorBase + file.path) ?? file.url
            try await fetcher.fetch(
                from: mirrorURL,
                to: destination,
                expectedBytes: file.sizeBytes,
                progress: progress
            )
            return try await verifyDownloaded(file: file, at: destination)
        }
    }

    private func verifyDownloaded(file: RemoteModelFile, at destination: URL) async throws -> String {
        try RemoteFileValidator.validateFile(at: destination, relativePath: file.path)

        let actualSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        if let expected = file.sizeBytes, actualSize != expected {
            throw ModelStoreError.sizeMismatch(file.path)
        }
        let digest = try await SHA256Verifier.fileDigestAsync(at: destination)
        if let expected = file.sha256, digest != expected.lowercased() {
            throw ModelStoreError.checksumMismatch(file.path)
        }
        return digest
    }

    private static func validExistingFileDigest(
        file: RemoteModelFile,
        at destination: URL
    ) async throws -> String? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try RemoteFileValidator.validateFile(at: destination, relativePath: file.path)
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        if let expected = file.sizeBytes, actualSize != expected { return nil }
        let digest = try await SHA256Verifier.fileDigestAsync(at: destination)
        if let expected = file.sha256 {
            return digest == expected.lowercased() ? digest : nil
        }
        return digest
    }

    public func delete(_ id: String, activeModelID: String?) throws {
        guard isInstalled(id) else { throw ModelStoreError.notInstalled }
        if id == activeModelID {
            throw ModelStoreError.modelIsActive
        }
        try FileManager.default.removeItem(at: modelDirectory(id))
        try? FileManager.default.removeItem(at: stagingDirectory(id))
    }

    /// 激活：从 metadata 构建 ModelAsset（含本机目录与格式），交由上层选择并装载引擎。
    public func activate(_ id: String) throws -> ModelAsset {
        guard let installed = listInstalled().first(where: { $0.id == id }) else {
            throw ModelStoreError.notInstalled
        }
        try RemoteFileValidator.validateModelDirectory(at: modelDirectory(id))
        return ModelAsset(
            id: installed.model.id,
            tier: installed.model.minTier,
            version: "1.0.0",
            sha256: installed.aggregateSHA256,
            sizeBytes: Int(installed.model.sizeBytes),
            capabilities: installed.model.capabilities,
            localDirectory: modelDirectory(id),
            format: installed.model.format,
            modelType: installed.model.modelType
        )
    }

    private static func availableVolumeBytes(at url: URL) -> Int64? {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else {
            return nil
        }
        return values[.systemFreeSize] as? Int64
    }

    private static func hasVerifiedExpectedFiles(
        _ files: [RemoteModelFile],
        in directory: URL
    ) async throws -> Bool {
        for file in files {
            let digest = try? await validExistingFileDigest(
                file: file,
                at: directory.appendingPathComponent(file.path)
            )
            guard digest != nil else { return false }
        }
        return true
    }
}

// MARK: - 内置开源模型目录（真实仓库，ADR 0005）

public enum OpenSourceModelCatalog {
    public static func defaultCatalog() -> [OpenSourceModel] {
        let mirrorBase = { (repo: String) in "https://hf-mirror.com/\(repo)/resolve/main/" }
        func supportedMLX(
            id: String, displayName: String, source: String, format: String,
            parameters: String, sizeBytes: Int64, license: String,
            minTier: ModelTier, modelType: String
        ) -> OpenSourceModel {
            OpenSourceModel(
                id: id,
                displayName: displayName,
                source: source,
                format: format,
                parameters: parameters,
                sizeBytes: sizeBytes,
                license: license,
                minTier: minTier,
                capabilities: [.chat],
                files: [],
                mirrorBase: mirrorBase(source),
                modelType: modelType,
                compatibility: .supported,
                compatibilityReason: "MLXLLM 支持该文字模型架构。",
                requiresOnlineManifest: true
            )
        }

        return [
            OpenSourceModel(
                id: "gemma-4-e2b-it-mlx-4bit",
                displayName: "Gemma 4 E2B (MLX 4-bit)",
                source: "mlx-community/gemma-4-e2b-it-4bit",
                format: "mlx-vlm-4bit", parameters: "E2B", sizeBytes: 3_600_000_000,
                license: "Gemma", minTier: .mainstream, capabilities: [.chat],
                files: [], mirrorBase: mirrorBase("mlx-community/gemma-4-e2b-it-4bit"),
                modelType: "gemma4",
                compatibility: .supported,
                compatibilityReason: "MLXVLM 支持该架构；当前仅启用纯文字对话。",
                requiresOnlineManifest: true
            ),
            OpenSourceModel(
                id: "minicpm-v-4.7-35b-a3b-mlx-4bit",
                displayName: "MiniCPM-V 4.7 35B-A3B (MLX 4-bit)",
                source: "mlx-community/MiniCPM-V-4.7-35B-A3B-OptiQ-4bit",
                format: "unsupported-mlx-vlm", parameters: "35B-A3B", sizeBytes: 20_000_000_000,
                license: "Apache-2.0", minTier: .flagship, capabilities: [],
                files: [], mirrorBase: nil,
                modelType: "minicpmv4_7",
                compatibility: .unsupported,
                compatibilityReason: "当前 MLX Swift LM registry 不支持 minicpmv4_7；图像输入也未实现。",
                requiresOnlineManifest: false
            ),
            OpenSourceModel(
                id: "mnn-pocket-0.3b",
                displayName: "MNN Pocket 0.3B",
                source: "taobao-mnn/MNN-Pocket-0.3B",
                format: "mnn-qwen3", parameters: "0.3B", sizeBytes: 350_000_000,
                license: "Apache-2.0", minTier: .entry, capabilities: [],
                files: [], mirrorBase: mirrorBase("taobao-mnn/MNN-Pocket-0.3B"),
                modelType: "qwen3",
                compatibility: .requiresConversion,
                compatibilityReason: "MNN 仓库的权重布局不能假定兼容 MLX；需要 MLX 转换版后重新检查。",
                requiresOnlineManifest: false
            ),
            supportedMLX(
                id: "qwen2.5-0.5b-instruct-mlx-4bit",
                displayName: "Qwen2.5 0.5B Instruct",
                source: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                format: "mlx-4bit", parameters: "0.5B", sizeBytes: 400_000_000,
                license: "Apache-2.0", minTier: .entry, modelType: "qwen2"
            ),
            supportedMLX(
                id: "qwen3-0.6b-mlx-4bit",
                displayName: "Qwen3 0.6B",
                source: "mlx-community/Qwen3-0.6B-4bit",
                format: "mlx-4bit", parameters: "0.6B", sizeBytes: 450_000_000,
                license: "Apache-2.0", minTier: .entry, modelType: "qwen3"
            ),
            supportedMLX(
                id: "llama-3.2-1b-instruct-mlx-4bit",
                displayName: "Llama 3.2 1B Instruct",
                source: "mlx-community/Llama-3.2-1B-Instruct-4bit",
                format: "mlx-4bit", parameters: "1B", sizeBytes: 700_000_000,
                license: "Llama 3.2", minTier: .entry, modelType: "llama"
            ),
            supportedMLX(
                id: "qwen2.5-1.5b-instruct-mlx-4bit",
                displayName: "Qwen2.5 1.5B Instruct",
                source: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                format: "mlx-4bit", parameters: "1.5B", sizeBytes: 1_000_000_000,
                license: "Qwen Research", minTier: .mainstream, modelType: "qwen2"
            ),
        ]
    }
}
