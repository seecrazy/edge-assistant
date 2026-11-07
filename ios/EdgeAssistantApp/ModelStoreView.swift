import SwiftUI
import EdgeAssistantCore

/// 应用内模型商店（ADR 0005）：浏览开源模型 → 下载部署 → 激活/删除。
struct ModelStoreView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = "qwen 4bit"

    var body: some View {
        NavigationStack {
            List {
                if let error = model.storeError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                installedSection
                residualSection
                discoverySection
                resultsSection
            }
            .navigationTitle("模型商店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
        .task { await model.refreshStore() }
    }

    private var availableModels: [OpenSourceModel] {
        model.storeCatalog.filter { candidate in
            !model.installedModels.contains { $0.id == candidate.id }
        }
    }

    private var installedSection: some View {
        Section {
            if model.installedModels.isEmpty, model.bundledAsset == nil {
                Text("暂无已安装模型")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let bundled = model.bundledAsset {
                bundledRow(bundled)
            }
            ForEach(model.installedModels) { installed in
                installedRow(installed)
            }
        } header: {
            Text("已安装")
        }
    }

    private var residualSection: some View {
        Group {
            if !model.residualInstallIDs.isEmpty {
                Section {
                    ForEach(model.residualInstallIDs, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(id)
                                .font(.subheadline)
                                .lineLimit(2)
                            Label("未完成安装、旧版残留或中断下载缓存；清理后可重新下载。", systemImage: "trash.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Button("清理残留", role: .destructive) {
                                model.cleanupResidualModel(id)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption2)
                            .disabled(model.isDownloading(id))
                        }
                    }
                } header: {
                    Text("残留与待清理")
                } footer: {
                    Text("清理只删除没有 metadata 的目录和中断 staging；正在使用的完整模型本体不会受影响。")
                        .font(.caption2)
                }
            }
        }
    }

    private var discoverySection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("搜索模型，如 qwen、gemma、smollm", text: $searchText)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await model.searchOnlineModels(searchText) }
                    }
                Button {
                    Task { await model.searchOnlineModels(searchText) }
                } label: {
                    if model.isRefreshingCatalog {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(model.isRefreshingCatalog)
            }
            Button {
                Task { await model.searchOnlineModels("mlx-community 4bit instruct") }
            } label: {
                Label("推荐轻量 MLX 模型", systemImage: "sparkles")
                    .font(.footnote)
            }
        } header: {
            Text("联网发现")
        } footer: {
            Text("搜索会扩展 MLX-community 和 4bit/8bit 量化仓库；架构仍会用 config.json 校验，非 MLX 布局不会提供下载。")
                .font(.caption2)
        }
    }

    private var resultsSection: some View {
        Section {
            if !model.isRefreshingCatalog, sortedAvailableModels.isEmpty, model.storeError == nil {
                Text("暂无可显示候选。试试 qwen、gemma、smollm 或 qwen3 4bit。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedAvailableModels) { candidate in
                catalogRow(candidate)
            }
        } header: {
            Text("可部署模型")
        } footer: {
            Text("轻量模型优先展示。内存标签用于快速选择；真实激活仍会检查本机内存，避免 iOS 直接杀掉 App。")
                .font(.caption2)
        }
    }

    private var sortedAvailableModels: [OpenSourceModel] {
        availableModels.sorted { left, right in
            let leftSupported = left.compatibility == .supported
            let rightSupported = right.compatibility == .supported
            if leftSupported != rightSupported { return leftSupported }
            if left.sizeBytes != right.sizeBytes { return left.sizeBytes < right.sizeBytes }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    private func installedRow(_ installed: InstalledModel) -> some View {
        let isActive = model.activeAssetID == installed.id
        let health = model.installHealth[installed.id] ?? .installed
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(installed.model.displayName).font(.subheadline).fontWeight(.semibold)
                Text("\(installed.model.parameters) · \(byteLabel(installed.model.sizeBytes)) · \(installed.model.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activationError = model.activationErrors[installed.id] {
                    Label(activationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if health == .incomplete {
                    Label("安装不完整，可修复或删除", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if model.activatingModelID == installed.id {
                Label("正在激活…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isActive {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("激活") { model.activateStoreModel(installed.id) }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(model.activatingModelID != nil)
            }
            if !isActive, health != .installed,
               model.storeCatalog.contains(where: { $0.id == installed.id }) {
                Button("修复下载") {
                    model.downloadModel(installed.id)
                }
                .buttonStyle(.bordered)
                .font(.caption2)
                .disabled(
                    model.activatingModelID != nil
                        || model.isResolvingManifest[installed.id] == true
                        || model.downloadProgress[installed.id] != nil
                )
            }
            Button(role: .destructive) {
                model.deleteStoreModel(installed.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(isActive)
        }
    }

    private func bundledRow(_ bundled: ModelAsset) -> some View {
        let isActive = model.activeAssetID == bundled.id
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("内置演示模型").font(.subheadline).fontWeight(.semibold)
                Text("Mock · 开箱即用 · 无需下载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("激活") { model.activateBundledModel() }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
    }

    private func catalogRow(_ candidate: OpenSourceModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text("\(candidate.parameters) · \(candidate.format) · \(candidate.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                compatibilityBadge(candidate.compatibility)
            }

            HStack(spacing: 6) {
                Label("\(byteLabel(candidate.sizeBytes))", systemImage: "arrow.down.doc")
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                Label(memoryLabel(candidate.sizeBytes), systemImage: "memorychip")
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(memoryColor(candidate.sizeBytes).opacity(0.13), in: Capsule())
                    .foregroundStyle(memoryColor(candidate.sizeBytes))
                if isHardwareRisk(candidate) {
                    Text("本机风险")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            if let reason = candidate.compatibilityReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(
                        candidate.compatibility == .supported ? Color.secondary : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isResolvingManifest[candidate.id] == true {
                HStack {
                    ProgressView()
                    Text("正在解析清单…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let progress = model.downloadProgress[candidate.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress)
                    HStack {
                        Text("下载中")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Button {
                        model.downloadModel(candidate.id)
                    } label: {
                        if model.activatingModelID == candidate.id {
                            Label("正在激活…", systemImage: "hourglass")
                                .font(.footnote)
                        } else {
                            Label("下载并部署", systemImage: "arrow.down.circle")
                                .font(.footnote)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        candidate.compatibility != .supported
                            || model.isResolvingManifest[candidate.id] == true
                            || model.activatingModelID != nil
                    )
                    Spacer()
                }
            }

            if model.isResolvingManifest[candidate.id] == true || model.downloadProgress[candidate.id] != nil {
                Button("取消下载") {
                    model.cancelDownload(candidate.id)
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }
            if let downloadError = model.downloadErrors[candidate.id] {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func byteLabel(_ bytes: Int64) -> String {
        String(format: "%.1fGB", Double(bytes) / 1_000_000_000)
    }

    private func memoryLabel(_ bytes: Int64) -> String {
        if bytes <= 2_000_000_000 { return "轻量" }
        if bytes <= 4_000_000_000 { return "中量" }
        return "重量"
    }

    private func memoryColor(_ bytes: Int64) -> Color {
        if bytes <= 2_000_000_000 { return .green }
        if bytes <= 4_000_000_000 { return .orange }
        return .red
    }

    private func compatibilityBadge(_ compatibility: ModelCompatibility?) -> some View {
        let text: String
        let color: Color
        switch compatibility {
        case .supported: text = "可用"; color = .green
        case .requiresConversion: text = "需转换"; color = .orange
        case .unsupported: text = "不支持"; color = .red
        case .unknown, nil: text = "待检查"; color = .gray
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private func isHardwareRisk(_ candidate: OpenSourceModel) -> Bool {
        guard candidate.compatibility == .supported else { return false }
        switch candidate.minTier {
        case .flagship: return model.profileTier != .flagship
        case .mainstream: return model.profileTier == .entry
        case .entry: return false
        }
    }
}
