import Foundation

public enum RegistryError: Error, Equatable {
    case invalidAsset([String])
    case unknownTier
}

/// 资产注册表，与 JS `createModelRegistry` 对齐。
public struct ModelRegistry: Sendable {
    private var assets: [ModelAsset] = []

    public init() {}

    public init(assets: [ModelAsset]) throws {
        for asset in assets { try register(asset) }
    }

    public mutating func register(_ asset: ModelAsset) throws {
        let validation = ModelAssetValidator.validate(asset)
        guard validation.isValid else { throw RegistryError.invalidAsset(validation.errors) }
        assets.append(asset)
    }

    public func list() -> [ModelAsset] { assets }

    public func latest(for tier: ModelTier) -> ModelAsset? {
        assets
            .filter { $0.tier == tier }
            .max { compareVersion($0.version, $1.version) < 0 }
    }

    public func resolve(for tier: ModelTier) -> (asset: ModelAsset?, modes: [CapabilityMode], reason: String?) {
        guard let asset = latest(for: tier) else {
            return (nil, [], "No registered model for \(tier.rawValue)")
        }
        return (asset, asset.capabilities, nil)
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        for i in 0..<3 {
            let li = i < l.count ? l[i] : 0
            let ri = i < r.count ? r[i] : 0
            if li != ri { return li - ri }
        }
        return 0
    }
}
