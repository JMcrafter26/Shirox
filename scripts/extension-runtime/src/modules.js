import { load } from "cheerio/slim";
import CryptoJS from "crypto-js";

const factories = new Map();
const cache = new Map();

export const cheerio = { load, default: { load } };

export function installModules(g) {
  const table = {
    cheerio,
    "cheerio-without-node-native": cheerio,
    "react-native-cheerio": cheerio,
    "crypto-js": CryptoJS,
    axios: g.axios,
  };
  g.CryptoJS ??= CryptoJS;
  g.require = (name) => {
    if (name in table) return table[name];
    throw new Error(`This plugin needs "${name}", which Shirox doesn't provide.`);
  };
  /// A CommonJS file, saved at install as `__extDefine("posts", function (module, exports, require) {…})`.
  g.__extDefine = (name, factory) => { factories.set(name, factory); cache.delete(name); };
  g.__extModule = (name) => {
    if (cache.has(name)) return cache.get(name);
    const factory = factories.get(name);
    if (!factory) return undefined;
    const module = { exports: {} };
    factory.call(g, module, module.exports, g.require);
    cache.set(name, module.exports);
    return module.exports;
  };
}
