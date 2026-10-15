import { load } from "cheerio/slim";

class Element {
  constructor($, node) { this.$ = $; this.node = node; }
  get sel() { return this.$(this.node); }
  wrap(node) { return node ? new Element(this.$, node) : null; }
  querySelector(q) { return this.wrap(this.sel.find(q).get(0)); }
  querySelectorAll(q) { return this.sel.find(q).toArray().map((n) => new Element(this.$, n)); }
  getElementsByTagName(t) { return this.querySelectorAll(t); }
  getElementById(id) { return this.querySelector(`#${id}`); }
  getAttribute(name) { const v = this.sel.attr(name); return v === undefined ? null : v; }
  hasAttribute(name) { return this.sel.attr(name) !== undefined; }
  closest(q) { return this.wrap(this.sel.closest(q).get(0)); }
  matches(q) { return this.sel.is(q); }
  get textContent() { return this.sel.text(); }
  get innerText() { return this.sel.text(); }
  get innerHTML() { return this.sel.html() ?? ""; }
  get outerHTML() { return this.$.html(this.node); }
  get children() { return this.sel.children().toArray().map((n) => new Element(this.$, n)); }
  get firstElementChild() { return this.children[0] ?? null; }
  get parentElement() { const p = this.node.parent; return p && p.type === "tag" ? new Element(this.$, p) : null; }
  get nextElementSibling() { return this.wrap(this.sel.next().get(0)); }
  get previousElementSibling() { return this.wrap(this.sel.prev().get(0)); }
  get tagName() { return String(this.node.name || "").toUpperCase(); }
  get nodeName() { return this.tagName; }
  get id() { return this.getAttribute("id") || ""; }
  get className() { return this.getAttribute("class") || ""; }
  get href() { return this.getAttribute("href") || ""; }
  get src() { return this.getAttribute("src") || ""; }
  get value() { return this.getAttribute("value") || ""; }
  get dataset() {
    const out = {};
    for (const [k, v] of Object.entries(this.node.attribs || {})) {
      if (k.startsWith("data-")) out[k.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = v;
    }
    return out;
  }
}

export function installDOM(g) {
  g.parseHtml = (html) => {
    const $ = load(String(html ?? ""));
    const doc = new Element($, $.root().get(0));
    Object.defineProperties(doc, {
      documentElement: { get: () => doc.querySelector("html") },
      body: { get: () => doc.querySelector("body") },
      head: { get: () => doc.querySelector("head") },
      title: { get: () => $("title").first().text() },
    });
    return doc;
  };
  g.parse_html = async (html, selector, attr) => {
    const $ = load(String(html ?? ""));
    return $(selector).toArray().map((n) => (attr ? $(n).attr(attr) ?? "" : $(n).text()));
  };
}
