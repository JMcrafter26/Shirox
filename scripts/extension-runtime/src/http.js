const lowerKeys = (h) => Object.fromEntries(Object.entries(h || {}).map(([k, v]) => [k.toLowerCase(), v]));
const hasHeader = (h, name) => Object.keys(h || {}).some((k) => k.toLowerCase() === name);

/// One request through the engine's fetch: { status, headers, body, url }.
export async function request({ url, method = "GET", headers = {}, body = null }) {
  const res = await globalThis.__extHostFetch(String(url), { method, headers, body });
  const text = typeof res.text === "function" ? await res.text() : String(res.body ?? "");
  return { status: res.status ?? 0, headers: res.headers || {}, body: text ?? "", url: res.url || String(url) };
}

function buildURL(url, base, params) {
  let u = String(url || "");
  if (base && !/^https?:/i.test(u)) u = base.replace(/\/$/, "") + "/" + u.replace(/^\//, "");
  if (params) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) q.append(k, String(v));
    const s = q.toString();
    if (s) u += (u.includes("?") ? "&" : "?") + s;
  }
  return u;
}

export function makeAxios(defaults = {}) {
  const ax = (urlOrConfig, config) =>
    ax.request(typeof urlOrConfig === "string" ? { ...(config || {}), url: urlOrConfig } : urlOrConfig);
  ax.defaults = { ...defaults, headers: { ...(defaults.headers || {}) } };
  ax.interceptors = { request: { use() { return 0; }, eject() {} }, response: { use() { return 0; }, eject() {} } };
  ax.request = async (config = {}) => {
    const c = { ...ax.defaults, ...config, headers: { ...(ax.defaults.headers || {}), ...(config.headers || {}) } };
    const headers = { ...c.headers };
    let body = c.data ?? null;
    if (body instanceof URLSearchParams) {
      body = body.toString();
      if (!hasHeader(headers, "content-type")) headers["Content-Type"] = "application/x-www-form-urlencoded";
    } else if (body && typeof body === "object") {
      body = JSON.stringify(body);
      if (!hasHeader(headers, "content-type")) headers["Content-Type"] = "application/json";
    }
    const res = await request({ url: buildURL(c.url, c.baseURL, c.params), method: String(c.method || "get").toUpperCase(), headers, body });
    let data = res.body;
    if (c.responseType !== "text") {
      const t = data.trimStart();
      if (t.startsWith("{") || t.startsWith("[")) { try { data = JSON.parse(data); } catch {} }
    }
    const out = { data, status: res.status, statusText: "", headers: lowerKeys(res.headers), config: c, request: { responseURL: res.url } };
    const ok = c.validateStatus ? c.validateStatus(res.status) : res.status >= 200 && res.status < 300;
    if (!ok) {
      const err = new Error(`Request failed with status code ${res.status}`);
      Object.assign(err, { response: out, config: c, isAxiosError: true });
      throw err;
    }
    return out;
  };
  for (const m of ["get", "delete", "head", "options"]) ax[m] = (url, config = {}) => ax.request({ ...config, url, method: m });
  for (const m of ["post", "put", "patch"]) ax[m] = (url, data, config = {}) => ax.request({ ...config, url, data, method: m });
  ax.create = (d = {}) => makeAxios({ ...ax.defaults, ...d, headers: { ...(ax.defaults.headers || {}), ...(d.headers || {}) } });
  ax.isAxiosError = (e) => !!(e && e.isAxiosError);
  ax.isCancel = () => false;
  ax.CancelToken = { source: () => ({ token: {}, cancel() {} }) };
  ax.all = (list) => Promise.all(list);
  ax.default = ax;
  return ax;
}

/// SkyStream passes either a headers object or { headers }.
function headersFrom(arg) {
  if (arg && typeof arg === "object" && arg.headers && typeof arg.headers === "object"
      && Object.keys(arg).every((k) => ["headers", "method", "body", "timeout"].includes(k))) return arg.headers;
  return arg || {};
}
const skyResponse = (r) => ({ status: r.status, statusCode: r.status, body: r.body, headers: r.headers, url: r.url });

export function installHTTP(g) {
  // The engine's own fetch, kept before a plugin or a bundled polyfill replaces the global.
  g.__extHostFetch = g.fetch;
  g.axios = makeAxios();
  g.http_get = async (url, opts) => skyResponse(await request({ url, headers: headersFrom(opts) }));
  g.http_post = async (url, headers, body) =>
    skyResponse(await request({ url, method: "POST", headers: headersFrom(headers),
      body: typeof body === "string" ? body : body == null ? null : JSON.stringify(body) }));
  g.http_parallel = (requests) => Promise.all((requests || []).map((r) =>
    request({ url: r.url, method: r.method || "GET", headers: r.headers || {}, body: r.body ?? null })
      .then(skyResponse, () => null)));

  class XMLHttpRequest {
    constructor() { this.readyState = 0; this.status = 0; this.responseText = ""; this.response = ""; this._headers = {}; this._resHeaders = {}; }
    open(method, url) { this._method = method; this._url = url; this.readyState = 1; }
    setRequestHeader(k, v) { this._headers[k] = v; }
    getResponseHeader(k) { return lowerKeys(this._resHeaders)[String(k).toLowerCase()] ?? null; }
    getAllResponseHeaders() { return Object.entries(this._resHeaders).map(([k, v]) => `${k}: ${v}`).join("\r\n"); }
    abort() {}
    send(body) {
      request({ url: this._url, method: this._method, headers: this._headers, body: body ?? null }).then((r) => {
        Object.assign(this, { readyState: 4, status: r.status, responseText: r.body, response: r.body, responseURL: r.url, _resHeaders: r.headers });
        this.onreadystatechange?.(); this.onload?.(); this.onloadend?.();
      }, (e) => { this.readyState = 4; this.onerror?.(e); this.onloadend?.(); });
    }
  }
  g.XMLHttpRequest ??= XMLHttpRequest;
}
