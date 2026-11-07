const test = require("node:test");
const assert = require("node:assert/strict");

const {
  validateModelAsset,
  verifyModelAsset,
  createModelRegistry,
  createSimulatedModelBundle,
  createModelAssetManager,
} = require("../prototype/js/model-registry.js");

function baseAsset(overrides = {}) {
  return {
    id: "flagship-1.0.0",
    tier: "flagship",
    version: "1.0.0",
    sha256: "a".repeat(64),
    sizeBytes: 1,
    capabilities: ["chat", "voice", "video"],
    ...overrides,
  };
}

test("validates required model asset metadata", () => {
  assert.equal(validateModelAsset(baseAsset()).valid, true);

  const invalid = validateModelAsset(
    baseAsset({
      tier: "unknown",
      version: "1.0",
      sha256: "bad",
      sizeBytes: -1,
      capabilities: ["phone"],
    })
  );
  assert.equal(invalid.valid, false);
  assert.match(invalid.errors.join(" "), /tier/);
  assert.match(invalid.errors.join(" "), /version/);
  assert.match(invalid.errors.join(" "), /sha256/);
  assert.match(invalid.errors.join(" "), /sizeBytes/);
  assert.match(invalid.errors.join(" "), /capabilities/);
});

test("verifies simulated model bytes by SHA-256", async () => {
  const bundle = await createSimulatedModelBundle("flagship", "1.0.0");
  const valid = await verifyModelAsset(bundle.asset, bundle.bytes);
  assert.equal(valid.valid, true);
  assert.equal(valid.actualSha256, bundle.asset.sha256);

  bundle.bytes[0] ^= 0xff;
  const invalid = await verifyModelAsset(bundle.asset, bundle.bytes);
  assert.equal(invalid.valid, false);
  assert.equal(invalid.reason, "sha256 mismatch");
});

test("registry selects the latest asset for a device tier", () => {
  const registry = createModelRegistry([
    baseAsset({ id: "a", version: "1.0.0", sha256: "b".repeat(64) }),
    baseAsset({ id: "b", version: "1.2.0", sha256: "c".repeat(64) }),
    baseAsset({
      id: "entry",
      tier: "entry",
      version: "0.9.0",
      sha256: "d".repeat(64),
      capabilities: ["chat", "voice"],
    }),
  ]);

  assert.equal(registry.latestForTier("flagship").id, "b");
  assert.deepEqual(registry.resolveForDevice("entry").supportedModes, ["chat", "voice"]);
  assert.equal(registry.resolveForDevice("mainstream").asset, null);
});

test("asset manager keeps the active model on failed install", async () => {
  const manager = createModelAssetManager();
  const goodBundle = await createSimulatedModelBundle("mainstream", "1.0.0");
  const installed = await manager.install(goodBundle.asset, goodBundle.bytes);
  assert.equal(installed.ok, true);

  const corruptBundle = await createSimulatedModelBundle("mainstream", "1.1.0", {
    corrupt: true,
  });
  const failed = await manager.install(
    corruptBundle.asset,
    new Uint8Array(corruptBundle.bytes)
  );
  assert.equal(failed.ok, false);
  assert.equal(failed.reason, "sha256 mismatch");
  assert.equal(manager.status().activeAsset.id, "mainstream-simulated-1.0.0");
  assert.match(manager.status().lastError, /sha256 mismatch/);
});

test("asset manager can roll back to the previous active model", async () => {
  const manager = createModelAssetManager();
  const first = await createSimulatedModelBundle("entry", "1.0.0");
  const second = await createSimulatedModelBundle("entry", "1.1.0");

  await manager.install(first.asset, first.bytes);
  await manager.install(second.asset, second.bytes);
  assert.equal(manager.status().activeAsset.version, "1.1.0");
  assert.equal(manager.status().rollbackAssetId, "entry-simulated-1.0.0");
  assert.equal(manager.status().rollbackAsset.version, "1.0.0");

  const rollback = await manager.rollback();
  assert.equal(rollback.ok, true);
  assert.equal(manager.status().activeAsset.version, "1.0.0");
  assert.equal(manager.status().rollbackAssetId, null);

  const noRollback = await manager.rollback();
  assert.equal(noRollback.ok, false);
  assert.equal(noRollback.reason, "no rollback asset available");
});

