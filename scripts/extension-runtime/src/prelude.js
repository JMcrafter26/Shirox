// Runs before the libraries. A JSContext has no URL, TextEncoder, AbortController or crypto,
// and the engine's atob/btoa go through UTF-8, which corrupts binary strings.
import { Buffer } from "buffer";

const g = globalThis;
g.global ??= g;
g.window ??= g;
g.self ??= g;
g.Buffer ??= Buffer;
g.atob = (s) => Buffer.from(String(s).replace(/[^A-Za-z0-9+/=_-]/g, ""), "base64").toString("binary");
g.btoa = (s) => Buffer.from(String(s), "binary").toString("base64");
g.queueMicrotask ??= (fn) => Promise.resolve().then(fn);

if (typeof g.AbortController !== "function") {
  class AbortSignal {
    constructor() { this.aborted = false; this.reason = undefined; this._listeners = []; this.onabort = null; }
    addEventListener(type, fn) { if (type === "abort") this._listeners.push(fn); }
    removeEventListener(type, fn) { this._listeners = this._listeners.filter((l) => l !== fn); }
    throwIfAborted() { if (this.aborted) throw this.reason; }
  }
  class AbortController {
    constructor() { this.signal = new AbortSignal(); }
    abort(reason) {
      const s = this.signal;
      if (s.aborted) return;
      s.aborted = true;
      s.reason = reason ?? new Error("Aborted");
      for (const l of s._listeners) { try { l({ type: "abort" }); } catch {} }
      if (typeof s.onabort === "function") { try { s.onabort({ type: "abort" }); } catch {} }
    }
  }
  g.AbortController = AbortController;
  g.AbortSignal = AbortSignal;
}

g.crypto ??= {};
g.crypto.getRandomValues ??= (array) => {
  for (let i = 0; i < array.length; i++) array[i] = Math.floor(Math.random() * 256);
  return array;
};
g.crypto.randomUUID ??= () => "10000000-1000-4000-8000-100000000000".replace(/[018]/g, (c) =>
  (c ^ (Math.floor(Math.random() * 256) & (15 >> (c / 4)))).toString(16));
