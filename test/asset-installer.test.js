const test = require("node:test");
const assert = require("node:assert/strict");

const { createModelAssetManager } = require("../prototype/js/model-registry.js");
const {
  createBundledAssetCatalog,
  createAutoInstaller,
} = require("../prototype/js/asset-installer.js");

test("bundled catalog provides a valid asset for every tier", async () => {
  const catalog = await createBundledAssetCatalog();

  assert.deepEqual(catalog.list().map((entry) => entry.tier), [
    "entry",
    "flagship",
    "mainstream",
  ]);
  for (const tier of ["flagship", "mainstream", "entry"]) {
    assert.equal(catalog.has(tier), true);
    const bundle = catalog.get(tier);
    assert.equal(bundle.asset.tier, tier);
    assert.match(bundle.asset.sha256, /^[0-9a-f]{64}$/);
    assert.ok(bundle.bytes.length > 0);
  }
  assert.equal(catalog.get("unknown"), null);
});

test("one-click install verifies and activates the bundled asset", async () => {
  const catalog = await createBundledAssetCatalog();
  const manager = createModelAssetManager();
  const events = [];
  const installer = createAutoInstaller({
    catalog,
    manager,
    onProgress: (event) => events.push(event.stage),
  });

  const result = await installer.installForTier("mainstream");
  assert.equal(result.ok, true);
  assert.equal(result.asset.tier, "mainstream");
  assert.equal(manager.status().activeAsset.id, result.asset.id);
  assert.deepEqual(events, ["storage-check", "verify", "activate"]);
});

test("corrupted bundled asset fails without replacing the active model", async () => {
  const catalog = await createBundledAssetCatalog();
  const good = catalog.get("entry");
  const manager = createModelAssetManager();
  await manager.install(good.asset, good.bytes);

  const corruptBundle = catalog.get("entry");
  corruptBundle.bytes[0] ^= 0xff;

  const installer = createAutoInstaller({
    catalog: {
      has: () => true,
      get: () => corruptBundle,
      list: () => [],
    },
    manager,
  });
  const result = await installer.installForTier("entry");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "sha256 mismatch");
  assert.equal(manager.status().activeAsset.id, good.asset.id);
});

test("insufficient storage fails before verification without intermediate writes", async () => {
  const catalog = await createBundledAssetCatalog();
  const manager = createModelAssetManager();
  const stages = [];
  const installer = createAutoInstaller({
    catalog,
    manager,
    freeBytes: 1024,
    onProgress: (event) => stages.push(`${event.stage}:${event.ok}`),
  });

  const result = await installer.installForTier("flagship");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "insufficient-storage");
  assert.ok(result.requiredBytes > result.availableBytes);
  assert.equal(manager.status().activeAsset, null);
  assert.deepEqual(stages, ["storage-check:false"]);
});

test("installer requires catalog and manager", () => {
  assert.throws(() => createAutoInstaller({}), /catalog and manager/);
});
