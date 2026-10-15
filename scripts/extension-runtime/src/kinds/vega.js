import { cfg, isAdultText, isTorrentURL, isHTTP, message, asJSON } from "../common.js";
import { request } from "../http.js";
import { cheerio } from "../modules.js";

const commonHeaders = {
  "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
  "Accept-Language": "en-US,en;q=0.9",
};
const kv = new Map();
let urls = null;

/// A provider's current site, from the repo's urls.json (`{ value: { url } }` or `{ value: "url" }`).
async function getBaseUrl(name) {
  if (!urls) {
    try { urls = JSON.parse((await request({ url: cfg().config.repoBase + "urls.json" })).body) || {}; } catch { urls = {}; }
  }
  const v = urls[name] ?? urls[cfg().key];
  return typeof v === "string" ? v : (v && v.url) || "";
}

function providerContext() {
  return {
    axios: globalThis.axios,
    cheerio,
    commonHeaders,
    getBaseUrl,
    Crypto: {
      digestStringAsync: async (algorithm, data) => {
        const name = String(algorithm).toUpperCase().replace("-", "");
        const fn = globalThis.CryptoJS[name] || globalThis.CryptoJS.SHA256;
        return fn(String(data)).toString();
      },
    },
    openWebView: async () => { throw new Error("Shirox can't open a challenge page for this provider."); },
    kvStore: {
      get: async (k) => kv.get(k), set: async (k, v) => { kv.set(k, v); }, delete: async (k) => kv.delete(k),
      keys: async () => [...kv.keys()], clear: async () => kv.clear(),
    },
  };
}

const part = (name) => globalThis.__extModule(name) || {};
const fail = (e) => { throw new Error(`${cfg().name}: ${message(e)}`); };
function call(name, fn, args) {
  return Promise.resolve().then(() => {
    const f = part(name)[fn];
    if (typeof f !== "function") throw new Error(`no ${fn}`);
    return f({ ...args, providerContext: providerContext(), signal: new AbortController().signal });
  }).catch(fail);
}

const metas = new Map();
function getMeta(link) {
  if (!metas.has(link)) metas.set(link, call("meta", "getMeta", { link, provider: cfg().key }).catch((e) => { metas.delete(link); throw e; }));
  return metas.get(link);
}

async function search(query) {
  const posts = await call("posts", "getSearchPosts", { searchQuery: query, page: 1, providerValue: cfg().key });
  return (posts || []).filter((p) => p && p.link && !isAdultText(p.title))
    .map((p) => ({ title: p.title || "", image: p.image || "", href: p.link }));
}

async function details(href) {
  const m = await getMeta(href);
  return [{ description: m.synopsis || "", aliases: (m.tags || []).join(", "), airdate: "" }];
}

const seasonOf = (title) => { const m = /season\s*(\d+)|\bs(\d{1,2})\b/i.exec(title || ""); return m ? Number(m[1] || m[2]) : null; };
const numberOf = (title, fallback) => { const m = /(?:episode|ep|e)\s*\.?\s*(\d+(?:\.\d+)?)/i.exec(title || ""); return m ? Number(m[1]) : fallback; };
const encode = (link, type) => "vega:" + JSON.stringify({ link, type });

async function episodes(href) {
  const m = await getMeta(href);
  const type = m.type || "series";
  const list = m.linkList || [];
  if (type === "movie") {
    const first = list.find((l) => (l.directLinks || []).length) || {};
    const link = (first.directLinks || [])[0];
    if (!link) throw new Error(`${cfg().name} has no links for this title.`);
    return [{ href: encode(link.link, link.type || "movie"), number: 1 }];
  }
  // One entry per season: the first quality listed for it. Entries without a season are qualities of one list.
  const chosen = [];
  const seen = new Set();
  for (const l of list) {
    const s = seasonOf(l.title) ?? 1;
    if (seen.has(s)) continue;
    seen.add(s);
    chosen.push({ s, l });
  }
  chosen.sort((a, b) => a.s - b.s);
  const out = [];
  for (const { l } of chosen) {
    let eps = l.directLinks || [];
    if (!eps.length && l.episodesLink && typeof part("episodes").getEpisodes === "function") {
      eps = (await call("episodes", "getEpisodes", { url: l.episodesLink })) || [];
    }
    eps.forEach((e, i) => out.push({ href: encode(e.link, e.type || type), n: numberOf(e.title, i + 1) }));
  }
  return chosen.length > 1 ? out.map((e, i) => ({ href: e.href, number: i + 1 })) : out.map((e) => ({ href: e.href, number: e.n }));
}

async function streams(href) {
  const { link, type } = JSON.parse(String(href).slice("vega:".length));
  const blocked = part("catalog").nonStreamableServer || [];
  const list = (await call("stream", "getStream", { link, type, isDownload: false })) || [];
  const out = [];
  const subtitles = [];
  for (const s of list) {
    if (!s || !isHTTP(s.link) || isTorrentURL(s.link) || s.type === "torrent" || blocked.includes(s.server)) continue;
    const quality = s.quality ? (/^\d+$/.test(String(s.quality)) ? `${s.quality}p` : String(s.quality)) : "";
    out.push({ title: [s.server, quality].filter(Boolean).join(" · ") || "Stream", streamUrl: s.link, headers: s.headers || {} });
    for (const t of s.subtitles || []) {
      if (t && t.uri && !subtitles.some((x) => x.url === t.uri)) subtitles.push({ url: t.uri, title: t.title || t.language || "Subtitle" });
    }
  }
  if (!out.length) throw new Error(`${cfg().name} found no playable streams for this episode.`);
  const result = { streams: out };
  if (subtitles.length) { result.subtitle = subtitles[0].url; result.allSubtitles = subtitles; }
  return result;
}

export function install(g) {
  g.__extFunctions = {
    searchResults: asJSON(search),
    extractDetails: asJSON(details),
    extractEpisodes: asJSON(episodes),
    extractStreamUrl: asJSON(streams),
  };
  Object.assign(g, g.__extFunctions);
}
