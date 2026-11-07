import Foundation

/// 按资产位置和格式选择后端；上层只依赖 `InferenceEngine`（ADR 0004/0006）。
public enum InferenceEngineFactory {
    public static func make(for asset: ModelAsset) -> any InferenceEngine {
        guard let directory = asset.localDirectory,
              let format = asset.format?.lowercased(),
              format.hasPrefix("mlx") else {
            return MockInferenceEngine()
        }
        if format.contains("vlm") {
            return MLXVisionLanguageEngine()
        }
        return MLXInferenceEngine()
    }
}
