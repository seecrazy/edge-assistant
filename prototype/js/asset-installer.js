/**
 * Bundled asset catalog + auto installer.
 *
 * 模拟移动端 install-time asset pack：模型在系统安装阶段随 App 写入设备，
 * 首次启动自动校验、激活并装载，聊天直接调用内置模型。
 * 编排契约：存储检查 → SHA-256 校验 → 激活 → 装载，任一步失败不改变已激活资产。
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory(require("./model-registry.js"));
  } else {
    root.EdgeAssistantAssetInstaller = factory(root.EdgeAssistantModelRegistry);
  }
})(
  typeof self !== "undefined" ? self : this,
  function (registryModule) {
    "use strict";

    const { MODEL_TIERS, createSimulatedModelBundle } = registryModule;

    const DEFAULT_FREE_BYTES = Number.POSITIVE_INFINITY;

    function cloneBundle(bundle) {
      return {
        asset: { ...bundle.asset, capabilities: [...bundle.asset.capabilities] },
        bytes: bundle.bytes.slice(),
      };
    }

    /**
     * 创建“自带资产目录”。真实实现中这里对接 Play Asset Delivery / On-Demand
     * Resources 的安装时资源；原型内用确定性模拟字节代替真实模型文件。
     */
    async function createBundledAssetCatalog(options = {}) {
      const tiers = options.tiers || [...MODEL_TIERS];
      const version = options.version || "1.0.0";
      const bundles = new Map();

      for (const tier of tiers) {
        if (!MODEL_TIERS.includes(tier)) {
          throw new Error(`unknown model tier: ${tier}`);
        }
        bundles.set(tier, await createSimulatedModelBundle(tier, version));
      }

      return {
        has(tier) {
          return bundles.has(tier);
        },
        get(tier) {
          const bundle = bundles.get(tier);
          return bundle ? cloneBundle(bundle) : null;
        },
        list() {
          return Array.from(bundles.keys()).sort().map((tier) => ({
            tier,
            asset: { ...bundles.get(tier).asset, capabilities: [...bundles.get(tier).asset.capabilities] },
          }));
        },
      };
    }

    /**
     * 自动装载编排器：启动时自动执行，无需用户操作。
     *
     * @param {object} options
     *   catalog    自带资产目录（createBundledAssetCatalog 返回值）
     *   manager    模型资产管理器（createModelAssetManager 返回值）
     *   onProgress 进度回调，收到 { stage, tier, ... }
     *   freeBytes  可用存储字节数（数字或函数），默认视为充足
     */
    function createAutoInstaller(options) {
      if (!options || !options.catalog || !options.manager) {
        throw new Error("catalog and manager are required");
      }

      const catalog = options.catalog;
      const manager = options.manager;
      const onProgress = options.onProgress || function () {};
      const freeBytesOption =
        options.freeBytes === undefined ? DEFAULT_FREE_BYTES : options.freeBytes;

      function availableBytes() {
        return typeof freeBytesOption === "function" ? freeBytesOption() : freeBytesOption;
      }

      async function installForTier(tier) {
        if (!MODEL_TIERS.includes(tier)) {
          throw new Error(`unknown model tier: ${tier}`);
        }

        const bundle = catalog.get(tier);
        if (!bundle) {
          onProgress({ stage: "storage-check", tier, ok: false });
          return { ok: false, reason: "no bundled asset for tier", status: manager.status() };
        }

        // 1. 存储检查：写入前进行，失败时不产生任何中间文件。
        const available = availableBytes();
        if (Number.isFinite(available) && available < bundle.asset.sizeBytes) {
          onProgress({ stage: "storage-check", tier, ok: false });
          return {
            ok: false,
            reason: "insufficient-storage",
            requiredBytes: bundle.asset.sizeBytes,
            availableBytes: available,
            status: manager.status(),
          };
        }
        onProgress({ stage: "storage-check", tier, ok: true, assetId: bundle.asset.id });

        // 2. SHA-256 校验 + 3. 激活：校验失败时 manager 保证不替换已激活资产。
        onProgress({ stage: "verify", tier, ok: true, assetId: bundle.asset.id });
        const result = await manager.install(bundle.asset, bundle.bytes);

        if (!result.ok) {
          onProgress({ stage: "activate", tier, ok: false, reason: result.reason });
          return {
            ok: false,
            reason: result.reason,
            expectedSha256: result.expectedSha256,
            actualSha256: result.actualSha256,
            status: result.status,
          };
        }

        onProgress({ stage: "activate", tier, ok: true, assetId: bundle.asset.id });
        return { ok: true, asset: bundle.asset, status: result.status };
      }

      return { installForTier };
    }

    return {
      createBundledAssetCatalog,
      createAutoInstaller,
    };
  }
);
