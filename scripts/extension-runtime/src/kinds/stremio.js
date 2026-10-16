import { cfg, media, isAdultText, isTorrentURL, isHTTP, firstLine, asJSON } from "../common.js";
import { request } from "../http.js";

const KITSU = "https://anime-kitsu.strem.fun";
const CINEMETA = "https://v3-cinemeta.strem.io";
const SHOW = "stremio:";
const VIDEO = "stremio-video:";

const conf = () => cfg().config || {};
const manifest = () => conf().manifest || {};
const own = () => conf().base;

function hasResource(name) {
  return (manifest().resources || []).some((r) => r === name || (r && r.name === name));
}
function streamPrefixes() {
  for (const r of manifest().resources || []) if (r && r.name === "stream") return r.idPrefixes || manifest().idPrefixes || null;
  return manifest().idPrefixes || null;
}
function ownSearchCatalog() {
  return (manifest().catalogs || []).find((c) => ["anime", "series", "movie"].includes(c.type)
    && (c.extra || []).some((e) => e.name === "search"));
}
/// Where shows come from: the addon's own catalog, Kitsu, or Cinemeta (StremioSupport.canSearch in Swift).
function source() {
  if (ownSearchCatalog() && hasResource("meta")) return "own";
  const p = streamPrefixes();
  if (!p || p.some((x) => x.startsWith("kitsu"))) return "kitsu";
  if (p.includes("tt")) return "cinemeta";
  return null;
}
const baseOf = (s) => (s === "own" ? own() : s === "kitsu" ? KITSU : CINEMETA);

async function getJSON(url) {
  const r = await request({ url });
  if (r.status < 200 || r.status >= 300) throw new Error(`${cfg().name} answered ${r.status}`);
  try { return JSON.parse(r.body); } catch { throw new Error(`${cfg().name} sent something that isn't JSON`); }
}

const adultMeta = (m) => !m || (m.genres || []).some(isAdultText) || isAdultText(m.name);
const item = (s, m) => ({ title: m.name || "", image: m.poster || "", href: SHOW + JSON.stringify({ s, t: m.type || "series", id: m.id }) });

async function search(query) {
  const s = source();
  if (!s) throw new Error("This addon has nothing Shirox can search.");
  // From an anime page: the show the AniList entry maps to first, then the search.
  const m = media();
  let mapped = [];
  if (m && s === "kitsu" && m.anilistId) {
    try {
      const meta = (await getJSON(`${KITSU}/meta/anime/anilist:${m.anilistId}.json`)).meta;
      if (meta && !adultMeta(meta)) mapped = [item(s, meta)];
    } catch {}
  }
  if (m && s === "cinemeta" && m.imdbId) {
    try {
      const type = m.tmdbType === "movie" ? "movie" : "series";
      const meta = (await getJSON(`${CINEMETA}/meta/${type}/${m.imdbId}.json`)).meta;
      if (meta && !adultMeta(meta)) mapped = [item(s, meta)];
    } catch {}
  }
  const q = encodeURIComponent(query);
  let urls;
  if (s === "own") {
    const c = ownSearchCatalog();
    urls = [`${own()}/catalog/${c.type}/${c.id}/search=${q}.json`];
  } else if (s === "kitsu") {
    urls = [`${KITSU}/catalog/anime/kitsu-anime-list/search=${q}.json`];
  } else {
    urls = [`${CINEMETA}/catalog/series/top/search=${q}.json`, `${CINEMETA}/catalog/movie/top/search=${q}.json`];
  }
  const lists = await Promise.all(urls.map((u) => getJSON(u).then((j) => j.metas || [], () => [])));
  const found = lists.flat().filter((x) => !adultMeta(x)).map((x) => item(s, x));
  return [...mapped, ...found.filter((f) => !mapped.some((x) => x.href === f.href))];
}

const parseShow = (href) => JSON.parse(String(href).slice(SHOW.length));

async function meta(href) {
  const { s, t, id } = parseShow(href);
  return (await getJSON(`${baseOf(s)}/meta/${t}/${id}.json`)).meta || {};
}

async function details(href) {
  const m = await meta(href);
  return [{ description: m.description || "", aliases: (m.aliases || []).join(", "), airdate: m.releaseInfo || m.released || "" }];
}

async function episodes(href) {
  const { t } = parseShow(href);
  const m = await meta(href);
  if (adultMeta(m)) throw new Error("Shirox doesn't play adult titles.");
  const ep = (v) => Number(v.episode ?? v.number ?? 0);
  const encode = (id) => VIDEO + JSON.stringify({ t, id });
  const videos = (m.videos || []).filter((v) => v && v.id && (v.season ?? 1) > 0);
  if (!videos.length) return [{ href: encode(m.id), number: 1 }];
  videos.sort((a, b) => (a.season ?? 1) - (b.season ?? 1) || ep(a) - ep(b));
  // From an anime page, for the show it maps to: only the AniList entry's part of its season
  // (Kitsu entries already are one). When that leaves nothing, the numbering differs: list it all.
  const md = media();
  if (md && md.season != null && md.imdbId && m.id === md.imdbId) {
    const offset = md.episodeOffset || 0;
    const end = md.episodeEnd ?? Infinity;
    const part = videos.filter((v) => v.season === md.season && ep(v) > offset && ep(v) <= end)
      .map((v) => ({ href: encode(v.id), number: ep(v) - offset }));
    if (part.length) return part;
  }
  if (new Set(videos.map((v) => v.season ?? 1)).size <= 1) return videos.map((v) => ({ href: encode(v.id), number: ep(v) }));
  return videos.map((v, i) => ({ href: encode(v.id), number: i + 1 }));
}

async function streams(href) {
  const { t, id } = JSON.parse(String(href).slice(VIDEO.length));
  const out = [];
  const subtitles = [];
  const answer = await getJSON(`${own()}/stream/${t}/${id}.json`);
  for (const s of answer.streams || []) {
    if (!s || s.infoHash || !isHTTP(s.url) || isTorrentURL(s.url)) continue;
    const title = [s.name, firstLine(s.title || s.description)].filter(Boolean).join(" · ") || "Stream";
    const hints = s.behaviorHints || {};
    out.push({ title, streamUrl: s.url, headers: (hints.proxyHeaders && hints.proxyHeaders.request) || {} });
    for (const sub of s.subtitles || []) if (sub && sub.url) subtitles.push({ url: sub.url, title: sub.lang || "Subtitle" });
  }
  if (!out.length) throw new Error("This addon has no playable streams for this episode (torrent links are skipped).");
  if (hasResource("subtitles")) {
    try {
      const subs = await getJSON(`${own()}/subtitles/${t}/${id}.json`);
      for (const sub of subs.subtitles || []) if (sub && sub.url) subtitles.push({ url: sub.url, title: sub.lang || "Subtitle" });
    } catch {}
  }
  const unique = subtitles.filter((x, i) => subtitles.findIndex((y) => y.url === x.url) === i);
  const result = { streams: out };
  if (unique.length) { result.subtitle = unique[0].url; result.allSubtitles = unique; }
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
