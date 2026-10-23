import { cfg, isAdultText, message } from "../common.js";

// Mana's enums (@mana-app/types): ContentRating, BridgeOperation, HttpMethod, BodyReader, RequestOrigin.
const EXPLICIT = 3;
const Op = { Fetch: 0, Read: 1, Release: 2, Cancel: 3, CreateBody: 4, RetainBody: 5, Invalidate: 6, BeginOperation: 7, EndOperation: 8 };
const methods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"];
const Origin = { Cover: 1, Page: 2 };
/// Titles up to MATURE: an explicit one is never asked for, and dropped if it comes anyway.
const sourceContext = { allowedContentRatings: [0, 1, 2] };

/// Response bodies by id. Sources rarely release them, so only the latest are kept: a body is
/// read (as Base64) right after its fetch, if at all.
const bodies = new Map();
const fetched = new Map();
const kept = 32;
let nextBody = 1;
function keep(text, request) {
  const id = nextBody++;
  bodies.set(id, text);
  if (request) fetched.set(id, request);
  for (const map of [bodies, fetched]) while (map.size > kept) map.delete(map.keys().next().value);
  return id;
}

const utf8Base64 = (text) => globalThis.Buffer.from(String(text), "utf8").toString("base64");

/// A request's cookies without the ones that ask a site for its adult titles — Madara sites'
/// `wpmanga-adault=1` and `toonily-mature=1` — so a mixed site serves what Shirox shows.
export function withoutAdultCookies(headers) {
  const out = { ...headers };
  for (const name of Object.keys(out)) {
    if (name.toLowerCase() !== "cookie") continue;
    const kept = String(out[name]).split(";").map((p) => p.trim())
      .filter((p) => p && !/^[^=]*(adult|adault|mature|nsfw|hentai|r18)[^=]*=/i.test(p));
    if (kept.length) out[name] = kept.join("; "); else delete out[name];
  }
  return out;
}

/// What a source's HttpClient (bundled into each `.mana`) asks of its host, over the engine's fetch.
/// Bodies are kept as text; a Base64 read of one (an image, an encrypted page) fetches it again as bytes.
function installBridge(g) {
  g.__manaHTTPBridge = {
    now: () => Date.now(),
    async send(m) {
      switch (m.operation) {
        case Op.Fetch: {
          if (m.bytes !== undefined || m.bodyKind === 3) throw new Error("Shirox can't send binary request bodies yet.");
          const init = { method: methods[m.method ?? 0] || "GET", headers: withoutAdultCookies(m.headers || {}), body: m.body ?? null };
          const res = await g.__extHostFetch(String(m.url), init);
          const text = typeof res.text === "function" ? await res.text() : String(res.body ?? "");
          const bodyID = keep(text ?? "", { url: String(m.url), init });
          return { status: res.status ?? 0, url: res.url || String(m.url), headers: res.headers || {}, bodyID, text: text ?? "" };
        }
        case Op.Read: {
          if (!bodies.has(m.bodyID)) throw new Error("Response body is no longer available");
          if (m.reader !== 1) return { value: bodies.get(m.bodyID) };
          // Fetched again as bytes: the engine's fetch hands back Base64 when asked (`base64Body`).
          const again = fetched.get(m.bodyID);
          if (!again) return { value: utf8Base64(bodies.get(m.bodyID)) };
          const res = await g.__extHostFetch(again.url, { ...again.init, base64Body: true });
          return { value: String(typeof res.text === "function" ? await res.text() : res.body ?? "") };
        }
        case Op.Release:
          bodies.delete(m.bodyID);
          fetched.delete(m.bodyID);
          return {};
        case Op.CreateBody:
          return { bodyID: keep(globalThis.Buffer.from(String(m.value ?? ""), "base64").toString("utf8")) };
        case Op.Cancel: case Op.RetainBody: case Op.Invalidate: case Op.BeginOperation: case Op.EndOperation:
          return {};
        default:
          throw new Error("Shirox can't run this part of the source yet.");
      }
    },
  };
}

/// In memory, per module context: what a source keeps between calls (a token, a domain).
function makeStore() {
  const items = new Map();
  return {
    get: async (k) => (items.has(k) ? JSON.parse(items.get(k)) : null),
    set: async (k, v) => { items.set(k, JSON.stringify(v)); },
    remove: async (k) => { items.delete(k); },
    string: async (k) => { const v = items.has(k) ? JSON.parse(items.get(k)) : null; return typeof v === "string" ? v : null; },
    boolean: async (k) => { const v = items.has(k) ? JSON.parse(items.get(k)) : null; return typeof v === "boolean" ? v : null; },
    number: async (k) => { const v = items.has(k) ? JSON.parse(items.get(k)) : null; return typeof v === "number" ? v : null; },
    stringArray: async (k) => { const v = items.has(k) ? JSON.parse(items.get(k)) : null; return Array.isArray(v) ? v : null; },
  };
}

/// Mana's `WebViewPage`, over the app's web views (ManaWebPages.swift). Pages a source leaves
/// open close when the call that opened them ends, as in Mana.
const openPages = new Set();
function makeWebViewPage(g) {
  const call = (op, payload) => new Promise((resolve, reject) => {
    if (typeof g.__shiroxWebView !== "function") { reject(new Error("Shirox can't open a web page for this source here.")); return; }
    g.__shiroxWebView(op, payload, resolve, (e) => reject(new Error(String(e))));
  });
  return {
    async create(options = {}) {
      const timeout = Number(options.timeout) > 0 ? Number(options.timeout) : 30;
      const id = await call("create", { timeout });
      let closed = false;
      const page = {
        goto: async (url, o = {}) => {
          await call("goto", { id, url: String(url), waitUntil: o.waitUntil || "load", timeout: Number(o.timeout) > 0 ? Number(o.timeout) : timeout });
        },
        evaluateScript: async (script, args = []) =>
          JSON.parse(await call("eval", { id, script: String(script), args: JSON.stringify(args ?? []), timeout })),
        // A function runs in the page as its source, with the helpers the bundle's build gave it.
        evaluate: (fn, ...args) =>
          page.evaluateScript(`${g.__manaSerializedFunctionPrelude || ""}\n;(${String(fn)})(...args)`, args),
        close: async () => {
          if (closed) return;
          closed = true;
          openPages.delete(page);
          await call("close", { id });
        },
      };
      openPages.add(page);
      return page;
    },
  };
}
const closePages = () => Promise.all([...openPages].map((p) => p.close().catch(() => {})));
/// A Luna function that closes the pages its call left open.
const closing = (f) => async (...args) => { try { return await f(...args); } finally { if (openPages.size) await closePages(); } };

let target = null;
let ready = null;
/// The source the module's script declared as `Target`, made once.
async function source() {
  if (!target) {
    const T = globalThis.Target;
    if (!T) throw new Error(`${cfg().name} has no source Shirox can run.`);
    target = typeof T === "function" ? new T() : T;
    ready = Promise.resolve().then(() => target.onEnvironmentLoaded?.()).catch((e) => console.log(`[mana] onEnvironmentLoaded: ${message(e)}`));
  }
  await ready;
  return target;
}

const fail = (e) => { throw new Error(`${cfg().name}: ${message(e)}`); };
const isExplicit = (item) => item && (item.contentRating >= EXPLICIT
  || (item.tags || []).some((t) => t && (t.contentRating >= EXPLICIT || (t.tags || []).some((x) => x && x.contentRating >= EXPLICIT))));

/// The address and headers an image goes out with: the source's cover or page transport, its
/// request interceptors run here, nothing sent. A transport that rewrites the image's bytes
/// (a response interceptor) isn't run — the reader loads pages itself.
async function imageRequest(s, url, origin) {
  const method = origin === Origin.Cover ? "getCoverTransport" : "getPageTransport";
  if (!url || typeof s[method] !== "function") return { url, headers: {} };
  try {
    const client = s[method]({ url, origin });
    if (!client || !client.headers) return { url, headers: {} };
    const Headers = client.headers.constructor;
    let request = { url: new URL(url, client.baseURL || undefined).href, fragmentParams: {}, method: 0, headers: new Headers(client.headers) };
    for (const intercept of client.requests || []) {
      request = await intercept(request, { requestId: "shirox", origin, attempt: 1, metadata: {} });
    }
    const headers = request.headers.toJSON ? request.headers.toJSON() : {};
    // URLSession sets these itself; an Accept-Encoding it can't decode (zstd) would garble the image.
    for (const name of Object.keys(headers)) if (/^(accept-encoding|host|content-length|connection)$/i.test(name)) delete headers[name];
    return { url: String(request.url).split("#")[0], headers };
  } catch (e) {
    console.log(`[mana] ${method}: ${message(e)}`);
    return { url, headers: {} };
  }
}

const contents = new Map();
function content(s, id) {
  if (!contents.has(id)) {
    contents.set(id, Promise.resolve(s.getContent(id, sourceContext)).catch((e) => { contents.delete(id); throw e; }));
  }
  return contents.get(id);
}

async function search(keyword) {
  try {
    const s = await source();
    if (typeof s.search !== "function") throw new Error("this source has no search");
    const result = await s.search({ query: String(keyword), page: 1, context: sourceContext });
    const items = ((result && result.results) || []).filter((h) => h && h.id != null && !h.noninteractive
      && !isExplicit(h) && !isAdultText(h.title));
    return Promise.all(items.map(async (h) => {
      const cover = await imageRequest(s, h.cover || "", Origin.Cover);
      const out = { id: String(h.id), title: String(h.title || ""), imageURL: cover.url || "" };
      if (Object.keys(cover.headers).length) out.imageHeaders = cover.headers;
      return out;
    }));
  } catch (e) { return fail(e); }
}

const tagTitles = (tags) => (tags || []).flatMap((t) => (t && Array.isArray(t.tags) ? tagTitles(t.tags) : t && t.title ? [String(t.title)] : []));

async function details(id) {
  try {
    const s = await source();
    const c = await content(s, String(id));
    if (isExplicit(c)) throw new Error("this title is adult, which Shirox doesn't show");
    return { description: String(c.summary || ""), tags: tagTitles(c.tags) };
  } catch (e) { return fail(e); }
}

/// A chapter's href carries its title's id with it — `getChapterData` needs both.
const chapterHref = (contentId, chapterId) => "mana:" + JSON.stringify([contentId, String(chapterId)]);
const chapters = new Map();

async function chapterList(s, contentId) {
  const c = await content(s, contentId);
  if (isExplicit(c)) throw new Error("this title is adult, which Shirox doesn't show");
  const list = Array.isArray(c.chapters) && c.chapters.length ? c.chapters
    : typeof s.getChapters === "function" ? await s.getChapters(contentId) : (c.chapters || []);
  for (const ch of list || []) if (ch && ch.chapterId != null) chapters.set(chapterHref(contentId, ch.chapterId), ch);
  return list || [];
}

/// Luna's `{ lang: [[label, [versions…]], …] }`: one language (English if there is one), the
/// versions of a number together, in the source's reading order.
async function extractChapters(id) {
  try {
    const s = await source();
    const contentId = String(id);
    const list = (await chapterList(s, contentId)).filter((ch) => ch && ch.chapterId != null);
    const langOf = (ch) => String(ch.language || "en").toLowerCase().split(/[_-]/)[0] || "en";
    const langs = [...new Set(list.map(langOf))];
    const lang = langs.includes("en") ? "en" : langs.sort()[0] || "en";
    const ordered = list.filter((ch) => langOf(ch) === lang)
      .map((ch, i) => ({ ch, i })).sort((a, b) => (a.ch.index ?? 0) - (b.ch.index ?? 0) || a.i - b.i).map((x) => x.ch);
    const groups = new Map();
    ordered.forEach((ch, i) => {
      const number = Number.isFinite(ch.number) ? ch.number : null;
      const label = number != null ? String(number) : String(ch.title || i + 1);
      const version = { id: chapterHref(contentId, ch.chapterId), title: ch.title ? String(ch.title) : "",
        scanlation_group: ch.provider && ch.provider.name ? String(ch.provider.name) : "" };
      if (number != null) version.chapter = number;
      if (!groups.has(label)) groups.set(label, []);
      groups.get(label).push(version);
    });
    return { [lang]: [...groups.entries()] };
  } catch (e) { return fail(e); }
}

async function extractImages(href) {
  try {
    const s = await source();
    const [contentId, chapterId] = JSON.parse(String(href).slice("mana:".length));
    const key = chapterHref(contentId, chapterId);
    if (!chapters.has(key)) await chapterList(s, contentId);
    const data = await s.getChapterData(contentId, chapterId, chapters.get(key));
    if (data && data.document && !(data.pages || []).length) {
      throw new Error("this chapter is a file (PDF, EPUB or CBZ), which Shirox can't open yet");
    }
    const pages = [];
    for (const p of (data && data.pages) || []) {
      if (p && p.url) {
        const r = await imageRequest(s, String(p.url), Origin.Page);
        pages.push(Object.keys(r.headers).length ? { url: r.url, headers: r.headers } : r.url);
      } else if (p && p.raw) {
        pages.push("data:image/jpeg;base64," + p.raw);
      }
    }
    if (!pages.length) throw new Error("this chapter has no pages");
    return pages;
  } catch (e) { return fail(e); }
}

/// The source's own description of itself — what install checks before keeping it.
async function info() {
  const s = await source();
  return s.info || null;
}

export function install(g) {
  installBridge(g);
  g.ObjectStore ??= makeStore();
  g.SecureStore ??= makeStore();
  g.WebViewPage ??= makeWebViewPage(g);
  // Luna's manga contract: raw values, which JSEngine+Manga stringifies.
  g.__extFunctions = { searchResults: closing(search), extractDetails: closing(details), extractChapters: closing(extractChapters),
    extractImages: closing(extractImages), __manaInfo: info };
  Object.assign(g, g.__extFunctions);
}
