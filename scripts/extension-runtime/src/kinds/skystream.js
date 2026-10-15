import { cfg, isAdultText, isTorrentURL, isHTTP, message, asJSON } from "../common.js";

const record = (defaults) => class { constructor(fields = {}) { Object.assign(this, defaults, fields); } };

/// Dean Edwards' P.A.C.K.E.R.: eval(function(p,a,c,k,e,d){…}('payload',radix,count,'words'.split('|')…))
function unpack(packed) {
  const m = /\}\s*\('([\s\S]*)',\s*(\d+),\s*(\d+),\s*'([\s\S]*?)'\.split\('\|'\)/.exec(packed || "");
  if (!m) return packed;
  const payload = m[1];
  const radix = Number(m[2]);
  let count = Number(m[3]);
  const words = m[4].split("|");
  const encode = (c) => (c < radix ? "" : encode(Math.floor(c / radix))) + ((c = c % radix) > 35 ? String.fromCharCode(c + 29) : c.toString(36));
  const dict = {};
  while (count--) dict[encode(count)] = words[count] || encode(count);
  return payload.replace(/\b\w+\b/g, (w) => dict[w] ?? w);
}

/// SkyStream answers through a callback: { success, data } or { success: false, error | message }.
function viaCallback(fn, ...args) {
  return new Promise((resolve, reject) => {
    if (typeof fn !== "function") return reject(new Error(`${cfg().name} doesn't support this.`));
    let settled = false;
    const cb = (r) => {
      if (settled) return;
      settled = true;
      if (r && r.success !== false) resolve(r.data);
      else reject(new Error(`${cfg().name}: ${(r && (r.error || r.message || r.errorCode)) || "failed"}`));
    };
    Promise.resolve().then(() => fn(...args, cb)).catch((e) => {
      if (!settled) { settled = true; reject(new Error(`${cfg().name}: ${message(e)}`)); }
    });
  });
}

const adultItem = (i) => !i || i.isAdult === true || /^(18\+|xxx|r18|hentai)$/i.test(String(i.contentRating || "")) || isAdultText(i.title);
const unplayable = (u) => !isHTTP(u) || isTorrentURL(u) || /^MAGIC_PROXY_v1|^magic_m3u8:/.test(u || "");

async function search(query) {
  const items = (await viaCallback(globalThis.search, query)) || [];
  return items.filter((i) => !adultItem(i) && i.type !== "livestream" && i.url)
    .map((i) => ({ title: i.title || "", image: i.posterUrl || "", href: i.url }));
}

async function details(href) {
  const i = (await viaCallback(globalThis.load, href)) || {};
  return [{ description: i.description || "", aliases: "", airdate: i.year ? String(i.year) : "" }];
}

async function episodes(href) {
  const i = (await viaCallback(globalThis.load, href)) || {};
  if (adultItem(i)) throw new Error("Shirox doesn't play adult titles.");
  const eps = (i.episodes || []).filter((e) => e && e.url && (e.season ?? 1) > 0);
  if (!eps.length) return [{ href: i.url || href, number: 1 }];
  eps.sort((a, b) => (a.season ?? 1) - (b.season ?? 1) || (a.episode ?? 0) - (b.episode ?? 0));
  const multi = new Set(eps.map((e) => e.season ?? 1)).size > 1;
  return eps.map((e, n) => ({ href: e.url, number: multi ? n + 1 : Number(e.episode ?? n + 1) }));
}

async function streams(href) {
  const list = (await viaCallback(globalThis.loadStreams, href)) || [];
  const out = [];
  const subtitles = [];
  for (const s of list) {
    if (!s || unplayable(s.url) || s.drmKid || s.drmKey || s.licenseUrl) continue;
    out.push({ title: [s.source || s.name, s.quality].filter(Boolean).join(" · ") || "Stream", streamUrl: s.url, headers: s.headers || {} });
    for (const t of s.subtitles || []) {
      if (t && t.url && !subtitles.some((x) => x.url === t.url)) subtitles.push({ url: t.url, title: t.label || t.lang || "Subtitle" });
    }
  }
  if (!out.length) throw new Error(`${cfg().name} found no playable streams for this episode.`);
  const result = { streams: out };
  if (subtitles.length) { result.subtitle = subtitles[0].url; result.allSubtitles = subtitles; }
  return result;
}

export function install(g) {
  g.manifest = { ...((cfg().config && cfg().config.manifest) || {}) };
  g.MultimediaItem = record({ type: "movie" });
  g.Episode = record({ season: 1, episode: 1 });
  g.StreamResult = record({});
  g.Actor = record({});
  g.Trailer = record({});
  g.NextAiring = record({});
  g.getAndUnpack = unpack;
  g.crypto.decryptAES = async (data, key, iv) => {
    const C = g.CryptoJS;
    const parse = (v) => (typeof v === "string" && /^[0-9a-f]+$/i.test(v) && v.length % 2 === 0 ? C.enc.Hex.parse(v) : C.enc.Utf8.parse(String(v)));
    return C.AES.decrypt(String(data), parse(key), { iv: parse(iv), mode: C.mode.CBC, padding: C.pad.Pkcs7 }).toString(C.enc.Utf8);
  };
  g.solveCaptcha = async () => { throw new Error("Shirox can't solve captchas for this plugin."); };
  // The plugin's own globals are `search`, `load` and `loadStreams`; Shirox's never take those names.
  g.__extFunctions = {
    searchResults: asJSON(search),
    extractDetails: asJSON(details),
    extractEpisodes: asJSON(episodes),
    extractStreamUrl: asJSON(streams),
  };
  Object.assign(g, g.__extFunctions);
}
