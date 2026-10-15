// The extension runtime for Shirox. The app evaluates it before a Stremio, Nuvio, Vega or
// SkyStream module's script, with `__ext` set (ExtensionScripts.swift).
import "./prelude.js";
import "./polyfills.js";
import { installHTTP } from "./http.js";
import { installModules } from "./modules.js";
import { installDOM } from "./dom.js";
import { cfg } from "./common.js";
import * as stremio from "./kinds/stremio.js";
import * as nuvio from "./kinds/nuvio.js";
import * as vega from "./kinds/vega.js";
import * as skystream from "./kinds/skystream.js";

const g = globalThis;
installHTTP(g);
installModules(g);
installDOM(g);
const kinds = { stremio, nuvio, vega, skystream };
kinds[cfg().kind]?.install(g);
