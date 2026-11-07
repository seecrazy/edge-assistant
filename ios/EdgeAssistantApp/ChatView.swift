import SwiftUI
import EdgeAssistantCore

struct ChatView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                messageList
                composer
            }
            .navigationTitle("Edge 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem {
                    Button {
                        model.showStore = true
                    } label: {
                        Label("模型", systemImage: "square.grid.2x2")
                    }
                    .accessibilityLabel("打开模型商店")
                }
                ToolbarItem {
                    Menu(content: {
                        Button {
                            model.showSearchSettings = true
                        } label: {
                            Label("联网与记忆", systemImage: "brain.head.profile")
                        }
                        Button(role: .destructive) {
                            model.clearAgentMemory()
                        } label: {
                            Label("清除记忆与会话", systemImage: "trash")
                        }
                    }, label: {
                        Image(systemName: "ellipsis.circle")
                    })
                }
            })
            .sheet(isPresented: $model.showStore) {
                ModelStoreView()
                    .environmentObject(model)
            }
            .sheet(isPresented: $model.showSearchSettings) {
                AgentSettingsView()
                    .environmentObject(model)
            }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if case .failed = model.provisionState {
                Button("重新校验") { model.retryProvision() }
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if model.thermalLevel != .normal {
                thermalBadge
                    .offset(y: 31)
            }
        }
    }

    private var statusColor: Color {
        switch model.provisionState {
        case .ready: return .green
        case .provisioning: return .orange
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.provisionState {
        case .provisioning:
            return "内置模型自动装载中…"
        case .ready:
            return "内置模型已就绪 · \(model.activeAssetID ?? "")"
        case let .failed(reason):
            return "装载失败：\(reason)"
        }
    }

    private var thermalBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(thermalColor)
                .frame(width: 7, height: 7)
            Text("热状态：\(thermalTitle)")
                .font(.caption2)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(thermalColor.opacity(0.6)))
        .accessibilityLabel("当前热状态：\(thermalTitle)")
    }

    private var thermalColor: Color {
        switch model.thermalLevel {
        case .normal: return .green
        case .warm: return .orange
        case .hot, .critical: return .red
        }
    }

    private var thermalTitle: String {
        switch model.thermalLevel {
        case .normal: return "正常"
        case .warm: return "略热"
        case .hot: return "较热"
        case .critical: return "过热"
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.messages.count) { _ in
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let stage = model.generationStage {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(stage == .preparing ? "正在准备本地推理…" : "本地生成中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("60 秒无首 token / 45 秒无增量会自动报错")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    model.isModelReady ? "输入问题…" : "等待内置模型装载…",
                    text: $model.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(!model.isModelReady)

                if model.isStreaming {
                    Button {
                        model.interrupt()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("打断")
                } else {
                    Button {
                        model.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !model.isModelReady
                            || model.isInferencePaused
                            || model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityLabel("发送")
                }
            }
            if model.isInferencePaused {
                Text("设备过热，推理已暂停；输入会保留。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .system:
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        case .user:
            bubble(alignment: .trailing, color: .accentColor.opacity(0.9), text_color: .white)
        case .assistant:
            bubble(alignment: .leading, color: Color(.systemGray5), text_color: .primary)
        case .source:
            VStack(alignment: .leading, spacing: 3) {
                Label("联网来源", systemImage: "network")
                    .font(.caption2)
                ForEach(message.text.split(separator: "\n"), id: \.self) { line in
                    if let url = URL(string: String(line)), url.scheme != nil {
                        Link(line, destination: url)
                            .font(.caption)
                            .lineLimit(2)
                    } else {
                        Text(line)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func bubble(alignment: HorizontalAlignment, color: Color, text_color: Color) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 48) }
            Text(message.text.isEmpty ? "…" : message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(color, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(text_color)
            if alignment == .leading { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

#Preview {
    ChatView().environmentObject(AppModel())
}

struct AgentSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("发送时联网检索", isOn: $enabled)
                    SecureField(model.hasSearchAPIKey ? "已保存 API Key（可更新）" : "Tavily API Key", text: $apiKey)
                    Button("保存设置") {
                        model.saveSearchSettings(enabled: enabled, apiKey: apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                    }
                    if model.hasSearchAPIKey {
                        Button(role: .destructive) {
                            model.deleteSearchAPIKey()
                            enabled = false
                            apiKey = ""
                        } label: {
                            Label("删除 API Key 并关闭检索", systemImage: "key.slash")
                        }
                    }
                } footer: {
                    Text("默认完全离线。开启后，仅检索词和搜索请求会离开设备；模型权重与推理仍在本地。API Key 保存在 Keychain。")
                        .font(.caption2)
                }

                Section("本地长期记忆") {
                    Text(model.agentStatus)
                        .font(.footnote)
                    if model.memoryRecords.isEmpty {
                        Text("暂无记忆")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    let pendingRecords = model.memoryRecords.filter { $0.status == .pending }
                    if !pendingRecords.isEmpty {
                        Text("待确认候选不会用于回答")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(pendingRecords) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.text)
                                .font(.footnote)
                            HStack {
                                Text("\(record.kind.displayName) · 推断")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("确认") { model.confirmMemory(record.id) }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                Button("忽略", role: .destructive) { model.dismissMemory(record.id) }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                    }

                    let confirmedRecords = model.memoryRecords.filter { $0.status == .confirmed }
                    ForEach(confirmedRecords) { record in
                        MemoryEditRow(record: record) { text in
                            if text != record.text {
                                model.updateMemory(record.id, text: text)
                            }
                        } onDelete: {
                            model.deleteMemory(record.id)
                        }
                    }
            }
            .navigationTitle("Agent 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }
            }
            .task {
                enabled = model.webSearchEnabled
            }
        }
    }
}

}

private struct MemoryEditRow: View {
    let record: AgentMemoryRecord
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String

    init(
        record: AgentMemoryRecord,
        onSave: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.record = record
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: record.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("记忆内容", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            HStack {
                Text("\(record.kind.displayName) · \(record.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存") { onSave(text) }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == record.text)
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
