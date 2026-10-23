// Builds Shirox/Resources/ExtensionRuntime.js. crypto-js tries `require("crypto")` for random
// numbers; for the browser target bun would bundle its whole Node crypto polyfill (~380 KB), so
// that one import resolves to nothing and crypto-js falls back to Math.random, as in a browser.
const banner = "/* Extension runtime for Shirox (Stremio, Nuvio, Vega, SkyStream, Mana). Bundles cheerio, crypto-js, buffer, core-js-pure (URL), fast-text-encoding (all MIT); see scripts/extension-runtime/README.md. */";

const noNodeCrypto = {
  name: "no-node-crypto",
  setup(build) {
    build.onResolve({ filter: /^(node:)?crypto$/ }, () => ({ path: "crypto", namespace: "empty" }));
    build.onLoad({ filter: /.*/, namespace: "empty" }, () => ({ contents: "module.exports = {};", loader: "js" }));
  },
};

const result = await Bun.build({
  entrypoints: ["src/runtime.js"],
  target: "browser",
  format: "iife",
  minify: true,
  banner,
  plugins: [noNodeCrypto],
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
await Bun.write("../../Shirox/Resources/ExtensionRuntime.js", result.outputs[0]);
console.log(`ExtensionRuntime.js ${(result.outputs[0].size / 1024).toFixed(0)} KB`);
