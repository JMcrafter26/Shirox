# Extension runtime

What Stremio addons and Nuvio, Vega and SkyStream plugins expect of their host, for Shirox's
JavaScriptCore engines. Built into `Shirox/Resources/ExtensionRuntime.js`, which the app loads
before a module whose `ext` is set (`ExtensionScripts.swift`).

- `src/prelude.js`: Buffer, binary-safe `atob`/`btoa`, `AbortController`, `crypto.getRandomValues`.
- `src/polyfills.js`: `TextEncoder`/`TextDecoder`, `URL`, `URLSearchParams`.
- `src/common.js`: `__ext`/`__shiroxMedia` access, adult-word and torrent checks, timeouts.
- `src/http.js`: requests over the engine's `fetch`, an axios shim, SkyStream's `http_get`/`http_post`/`http_parallel`, `XMLHttpRequest`.
- `src/modules.js`: `require` (cheerio, crypto-js, axios) and `__extDefine`/`__extModule` for CommonJS files.
- `src/dom.js`: SkyStream's `parseHtml` DOM, over cheerio.
- `src/kinds/*.js`: Shirox's module functions for each kind.
- `build.js`: the bundle (crypto-js's optional `require("crypto")` resolves to nothing, keeping bun's Node crypto polyfill out).

Build with bun (below 1.4.0): `bun install`, then `bun run build`. Commit the built file.

Bundled libraries, all MIT: cheerio (© Matt Mueller and contributors), crypto-js (© Jeff Mott,
Evan Vosberg), buffer (© Feross Aboukhadijeh), core-js-pure (© Denis Pushkarev),
fast-text-encoding (© Sam Thorogood).
