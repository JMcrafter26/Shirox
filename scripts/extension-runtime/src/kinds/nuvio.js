import { cfg, media, isTorrentURL, isHTTP, firstLine, withTimeout, message, asJSON } from "../common.js";
import { request } from "../http.js";

const TMDB = "https://api.themoviedb.org/3";
const IMAGE = "https://image.tmdb.org/t/p/w500";

async function tmdb(path, query = "") {
  const url = `${TMDB}${path}?api_key=${cfg().tmdbKey}&include_adult=false${query}`;
  const r = await request({ url });
  if (r.status < 200 || r.status >= 300) throw new Error(`TMDB answered ${r.status}`);
  return JSON.parse(r.body);
}

const types = () => (cfg().config && cfg().config.supportedTypes) || ["movie", "tv"];
const item = (type, r) => ({ title: r.name || r.title || "", image: r.poster_path ? IMAGE + r.poster_path : "", href: `tmdb:${type}:${r.id}` });

async function search(query) {
  const m = media();
  if (m && m.tmdbId && types().includes(m.tmdbType)) {
    try {
      const r = await tmdb(`/${m.tmdbType}/${m.tmdbId}`);
      if (!r.adult) return [item(m.tmdbType, r)];
    } catch {}
  }
  const r = await tmdb("/search/multi", `&query=${encodeURIComponent(query)}`);
  return (r.results || []).filter((x) => types().includes(x.media_type) && !x.adult).map((x) => item(x.media_type, x));
}

const parse = (href) => { const [, type, id, season, episode] = String(href).split(":"); return { type, id, season, episode }; };

async function details(href) {
  const { type, id } = parse(href);
  const r = await tmdb(`/${type}/${id}`);
  return [{ description: r.overview || "", aliases: r.original_name || r.original_title || "", airdate: r.first_air_date || r.release_date || "" }];
}

async function episodes(href) {
  const { type, id } = parse(href);
  if (type === "movie") return [{ href: `tmdb:movie:${id}`, number: 1 }];
  // From an anime page: only the AniList entry's part of its season.
  const m = media();
  if (m && String(m.tmdbId) === String(id) && m.season != null) {
    const offset = m.episodeOffset || 0;
    const s = await tmdb(`/tv/${id}/season/${m.season}`);
    return (s.episodes || []).filter((e) => e.episode_number > offset)
      .map((e) => ({ href: `tmdb:tv:${id}:${m.season}:${e.episode_number}`, number: e.episode_number - offset }));
  }
  const show = await tmdb(`/tv/${id}`);
  const seasons = (show.seasons || []).map((s) => s.season_number).filter((n) => n > 0).sort((a, b) => a - b);
  const lists = await Promise.all(seasons.map((n) =>
    tmdb(`/tv/${id}/season/${n}`).then((s) => ({ n, eps: s.episodes || [] }), () => ({ n, eps: [] }))));
  const out = [];
  for (const { n, eps } of lists) for (const e of eps) out.push({ href: `tmdb:tv:${id}:${n}:${e.episode_number}`, number: out.length + 1 });
  return out;
}

async function streams(href) {
  const { type, id, season, episode } = parse(href);
  const mod = globalThis.__extModule("main") || {};
  const getStreams = mod.getStreams || (mod.default && mod.default.getStreams) || globalThis.getStreams;
  if (typeof getStreams !== "function") throw new Error(`${cfg().name} has no getStreams.`);
  const list = await withTimeout(
    Promise.resolve().then(() => getStreams(String(id), type, season ? Number(season) : undefined, episode ? Number(episode) : undefined)),
    30000, cfg().name).catch((e) => { throw new Error(`${cfg().name}: ${message(e)}`); });
  const out = [];
  for (const s of list || []) {
    if (!s || !isHTTP(s.url) || isTorrentURL(s.url)) continue;
    const title = [s.name, firstLine(s.title)].filter(Boolean).join(" · ") || "Stream";
    out.push({ title: s.quality && !title.includes(s.quality) ? `${title} · ${s.quality}` : title, streamUrl: s.url, headers: s.headers || {} });
  }
  if (!out.length) throw new Error(`${cfg().name} found no playable streams for this episode.`);
  return { streams: out };
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
