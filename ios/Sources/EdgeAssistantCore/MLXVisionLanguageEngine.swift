import Foundation
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// 当前 VLM 只走文字 chat；图像/视频 request model 和 UI 是后续设计。
public final class MLXVisionLanguageEngine: MLXInferenceEngine, @unchecked Sendable {
    override func loadContainer(from directory: URL) async throws -> ModelContainer {
        try await VLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
    }

    override func systemPrompt(maxOutputChars: Int) -> String {
        "你是运行在用户设备本地的多模态模型。当前对话只使用文字输入，请用简体中文简洁回答。"
    }
}
