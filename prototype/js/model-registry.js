(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.EdgeAssistantModelRegistry = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const MODEL_TIERS = Object.freeze(["flagship", "mainstream", "entry"]);
  const SUPPORTED_MODES = Object.freeze(["chat", "voice", "video"]);

  function isHexSha256(value) {
    return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
  }

  function validateModelAsset(asset) {
    const errors = [];

    if (!asset || typeof asset !== "object") {
      return { valid: false, errors: ["asset must be an object"] };
    }
    if (typeof asset.id !== "string" || asset.id.length === 0) {
      errors.push("id is required");
    }
    if (!MODEL_TIERS.includes(asset.tier)) {
      errors.push("tier must be flagship, mainstream, or entry");
    }
    if (typeof asset.version !== "string" || !/^\d+\.\d+\.\d+$/.test(asset.version)) {
      errors.push("version must use semver x.y.z");
    }
    if (!isHexSha256(asset.sha256)) {
      errors.push("sha256 must be a 64-character hexadecimal string");
    }
    if (!Number.isSafeInteger(asset.sizeBytes) || asset.sizeBytes <= 0) {
      errors.push("sizeBytes must be a positive safe integer");
    }
    if (
      !Array.isArray(asset.capabilities) ||
      asset.capabilities.length === 0 ||
      asset.capabilities.some((mode) => !SUPPORTED_MODES.includes(mode))
    ) {
      errors.push("capabilities must be a non-empty subset of chat, voice, and video");
    }

    return {
      valid: errors.length === 0,
      errors,
    };
  }

  function toBytes(input) {
    if (input instanceof Uint8Array) {
      return input;
    }
    if (input instanceof ArrayBuffer) {
      return new Uint8Array(input);
    }
    if (ArrayBuffer.isView(input)) {
      return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    }
    return null;
  }

  async function hashSha256Hex(bytes) {
    const data = toBytes(bytes);
    if (!data) {
      throw new TypeError("bytes must be Uint8Array, ArrayBuffer, or an ArrayBuffer view");
    }

    const digest = await crypto.subtle.digest("SHA-256", data);
    return Array.from(new Uint8Array(digest))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
  }

  async function verifyModelAsset(asset, bytes) {
    const validation = validateModelAsset(asset);
    if (!validation.valid) {
      return {
        valid: false,
        reason: validation.errors.join("; "),
        expectedSha256: asset ? asset.sha256 : undefined,
        actualSha256: undefined,
      };
    }

    const actualSha256 = await hashSha256Hex(bytes);
    return {
      valid: actualSha256.toLowerCase() === asset.sha256.toLowerCase(),
      reason:
        actualSha256.toLowerCase() === asset.sha256.toLowerCase()
          ? null
          : "sha256 mismatch",
      expectedSha256: asset.sha256.toLowerCase(),
      actualSha256,
    };
  }

  function compareVersion(a, b) {
    const left = a.version.split(".").map(Number);
    const right = b.version.split(".").map(Number);
    for (let index = 0; index < 3; index += 1) {
      if (left[index] !== right[index]) {
        return left[index] - right[index];
      }
    }
    return 0;
  }

  function createModelRegistry(assets) {
    const registered = new Map();

    function register(asset) {
      const validation = validateModelAsset(asset);
      if (!validation.valid) {
        throw new Error(`Invalid model asset: ${validation.errors.join("; ")}`);
      }
      registered.set(asset.id, { ...asset, capabilities: [...asset.capabilities] });
      return registered.get(asset.id);
    }

    function list() {
      return Array.from(registered.values()).map((asset) => ({
        ...asset,
        capabilities: [...asset.capabilities],
      }));
    }

    function latestForTier(tier) {
      if (!MODEL_TIERS.includes(tier)) {
        throw new Error("unknown model tier");
      }
      const candidates = list().filter((asset) => asset.tier === tier);
      if (candidates.length === 0) {
        return null;
      }
      return candidates.sort((a, b) => compareVersion(b, a))[0];
    }

    function resolveForDevice(deviceTier) {
      const asset = latestForTier(deviceTier);
      if (!asset) {
        return {
          asset: null,
          supportedModes: [],
          reason: `No registered model for ${deviceTier}`,
        };
      }
      return {
        asset,
        supportedModes: [...asset.capabilities],
        reason: null,
      };
    }

    (Array.isArray(assets) ? assets : []).forEach(register);

    return {
      register,
      list,
      latestForTier,
      resolveForDevice,
    };
  }

  async function createSimulatedModelBundle(tier, version = "0.1.0", options = {}) {
    if (!MODEL_TIERS.includes(tier)) {
      throw new Error("unknown model tier");
    }

    const sizes = {
      flagship: 2_250_000_000,
      mainstream: 1_250_000_000,
      entry: 800_000_000,
    };
    const capabilities =
      tier === "entry" ? ["chat", "voice"] : ["chat", "voice", "video"];

    const bytes = new TextEncoder().encode(
      `edge-assistant:simulated-model:${tier}:${version}`
    );
    const sha256 = await hashSha256Hex(bytes);
    if (options.corrupt === true) {
      bytes[0] ^= 0xff;
    }
    return {
      asset: {
        id: `${tier}-simulated-${version}`,
        tier,
        version,
        sha256,
        sizeBytes: sizes[tier],
        capabilities,
      },
      bytes,
    };
  }

  function createModelAssetManager(options = {}) {
    const verify = options.verify || verifyModelAsset;
    let activeAsset = null;
    let rollbackAsset = null;
    let lastError = null;
    let installCount = 0;

    function status() {
      return {
        activeAsset: activeAsset
          ? { ...activeAsset, capabilities: [...activeAsset.capabilities] }
          : null,
        rollbackAsset: rollbackAsset
          ? { ...rollbackAsset, capabilities: [...rollbackAsset.capabilities] }
          : null,
        rollbackAssetId: rollbackAsset ? rollbackAsset.id : null,
        lastError,
        installCount,
      };
    }

    async function install(asset, bytes) {
      const result = await verify(asset, bytes);
      installCount += 1;

      if (!result.valid) {
        lastError = result.reason || "asset verification failed";
        return {
          ok: false,
          reason: lastError,
          expectedSha256: result.expectedSha256,
          actualSha256: result.actualSha256,
          status: status(),
        };
      }

      const previousAsset = activeAsset;
      activeAsset = { ...asset, capabilities: [...asset.capabilities] };
      rollbackAsset = previousAsset;
      lastError = null;

      return {
        ok: true,
        previousAssetId: previousAsset ? previousAsset.id : null,
        status: status(),
      };
    }

    async function rollback() {
      if (!rollbackAsset) {
        return {
          ok: false,
          reason: "no rollback asset available",
          status: status(),
        };
      }

      activeAsset = rollbackAsset;
      rollbackAsset = null;
      lastError = null;
      return {
        ok: true,
        status: status(),
      };
    }

    return {
      install,
      rollback,
      status,
    };
  }

  return {
    MODEL_TIERS,
    SUPPORTED_MODES,
    validateModelAsset,
    hashSha256Hex,
    verifyModelAsset,
    createModelRegistry,
    createSimulatedModelBundle,
    createModelAssetManager,
  };
});

