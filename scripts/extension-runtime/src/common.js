export const cfg = () => globalThis.__ext || { kind: "", name: "Extension", key: "", config: {}, tmdbKey: "", adultWords: [] };
export const media = () => globalThis.__shiroxMedia || null;

/// Whole words from Swift's adult list (NSFWContentFilter + AdultModuleCheck stems), and the
/// stems inside longer words ("hentaihaven").
export function isAdultText(text) {
  if (!text) return false;
  const words = cfg().adultWords || [];
  // "Adult Swim" is a channel, not an adult rating — as in Swift's AdultModuleCheck.
  const tokens = String(text).toLowerCase().replace(/\badult\s+swim\b/g, " ").split(/[^a-z0-9]+/).filter(Boolean);
  const stems = ["hentai", "porn", "xxx", "nsfw", "rule34"];
  return tokens.some((t) => words.includes(t) || stems.some((s) => t.includes(s)));
}

export const isTorrentURL = (url) => /^magnet:/i.test(url || "") || /\.torrent(\?|#|$)/i.test(url || "");
export const isHTTP = (url) => /^https?:\/\//i.test(url || "");

/** A stream's row: its name, and under it every line of its description, as Stremio and Nuvio
 *  show them (source, codec, audio and languages, dub, size). Without a name, the first line. */
export function streamLabel(name, text) {
  const lines = String(text || "").split("\n").map((l) => l.trim()).filter(Boolean);
  const title = String(name || "").replace(/\s+/g, " ").trim() || lines.shift() || "Stream";
  return lines.length ? { title, details: lines.join("\n") } : { title };
}

export function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const id = setTimeout(() => reject(new Error(`${label} took longer than ${Math.round(ms / 1000)} s`)), ms);
    Promise.resolve(promise).then(
      (v) => { clearTimeout(id); resolve(v); },
      (e) => { clearTimeout(id); reject(e); });
  });
}

/// A thrown value as a message, for errors that reach Shirox.
export const message = (e) => String((e && (e.message || e.error)) || e || "Unknown error");

/// Shirox's module functions answer in JSON strings.
export const asJSON = (f) => async (...a) => JSON.stringify(await f(...a));
