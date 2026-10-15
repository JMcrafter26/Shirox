// After the prelude: these read TextEncoder/Buffer as they load.
import "fast-text-encoding";
import URL from "core-js-pure/stable/url/index.js";
import URLSearchParams from "core-js-pure/stable/url-search-params/index.js";

globalThis.URL ??= URL;
globalThis.URLSearchParams ??= URLSearchParams;
