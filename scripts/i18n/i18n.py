#!/usr/bin/env python3
"""Shirox's string catalog tooling. Every user-facing string in the Swift sources is a key such as
`settings.portrait_only`, and its English text lives in Shirox/Localizable.xcstrings.

    python3 -I scripts/i18n/i18n.py check [files…]   # fails on hardcoded UI text or keys without English
    python3 -I scripts/i18n/i18n.py inventory        # scripts/i18n/inventory.csv: what's still hardcoded
    python3 -I scripts/i18n/i18n.py extract FILE…     # turns the hardcoded text in FILEs into keys
    python3 -I scripts/i18n/i18n.py sync [--build DIR] [--prune]  # adds the keys a build found to the
                                                     # catalog; --prune drops ones no longer in code
    python3 -I scripts/i18n/i18n.py loose [files…]    # other text-like literals, to review by hand
    python3 -I scripts/i18n/i18n.py rename FILE      # renames keys everywhere, from `old new` lines
    python3 -I scripts/i18n/i18n.py import LANG FILE # adds a language from a JSON of key -> text

A key is `<area>.<up to five words>`, lowercase with underscores. Arguments stay in the key as
interpolations, `Text("detail.download_episodes \\(count)")`, and the catalog holds the sentence
around them: "Download %lld Episodes". Text that must stay as written takes `// i18n-ignore` at the
end of its line.

Adding a string: write the key in the code, put it and its English text in the catalog (Xcode adds
the key on build; fill in the English), and run `check`. Adding a language: translate the catalog's
English into a JSON of key -> text and `import` it (or fill in the column in Xcode), and add the
language to the project's known regions; it shows up in Settings › General › Change Language by itself.
"""
import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SOURCES = os.path.join(ROOT, "Shirox")
CATALOG = os.path.join(SOURCES, "Localizable.xcstrings")
TEXTS = os.path.join(HERE, "texts.json")
INVENTORY = os.path.join(HERE, "inventory.csv")
DEFAULT_BUILD = os.path.join(ROOT, "build", "DDMacDbg")

# A Swift string literal on one line: escapes allowed, interpolations kept as written.
LIT = r'"((?:[^"\\\n]|\\.)*)"'

# Where a literal is shown to the user, and so needs a key. `view` and `modifier` take a
# LocalizedStringKey, so the key goes in as it is; the rest are Strings: `String(localized:)`.
PATTERNS = [
    ("view", re.compile(r'(?<![\w.])(?:Text|Label|Button|Toggle|Picker|Section|LabeledContent|Link|TextField|'
                        r'SecureField|Menu|NavigationLink|ContentUnavailableView|Stepper|Tab|ColorPicker|CommandMenu)'
                        r'\(\s*' + LIT)),
    ("modifier", re.compile(r'\.(?:navigationTitle|alert|confirmationDialog|accessibilityLabel|'
                            r'accessibilityHint|help|badge)\(\s*' + LIT)),
    ("argument", re.compile(r'\b(?:message|title|subtitle|heading|prompt|placeholder|label|detail|'
                            r'description|footer|header)\s*:\s*' + LIT)),
    ("returned", re.compile(r'\breturn\s+' + LIT)),
    ("case", re.compile(r'\bcase\s+[^:]+:\s*return\s+' + LIT)),
]

SKIP_LINE = re.compile(r'Logger\.shared\.log|print\(|UserDefaults|forKey:|NSLog|fatalError|assert|'
                       r'#selector|evaluateJavaScript|\.log\(|i18n-ignore')

# The areas keys start with; anything else with a dot is a symbol or file name.
AREA_NAMES = ("app", "common", "settings", "player", "reader", "downloads", "library", "profile",
              "onboarding", "simkl", "home", "search", "jellyfin", "modules", "detail", "shared")
KEY = re.compile(r'^(?:' + "|".join(AREA_NAMES) + r')\.(?!(?:json|js|com|org|net|html|txt)$)[a-z0-9_]+$')
INTERPOLATION = re.compile(r'\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)')

# What comes right before a literal that's code, not text: lookups, comparisons, resources.
NOT_UI_CONTEXT = re.compile(r'(?:\[|==\s*|!=\s*|\bcase\s+|hasPrefix\(|hasSuffix\(|contains\(|'
                            r'components\(separatedBy:\s*|replacingOccurrences\(of:\s*|with:\s*|'
                            r'named:\s*|Image\(|systemName:\s*|systemImage:\s*|URL\(string:\s*|'
                            r'forResource:\s*|withExtension:\s*|forInfoDictionaryKey:\s*|rawValue:\s*|'
                            r'Notification\.Name\(|forHTTPHeaderField:\s*|value\(forKey:\s*|'
                            r'identifier:\s*|id:\s*|key:\s*|type:\s*|name:\s*|scheme:\s*|host:\s*|'
                            r'path:\s*|fileName:\s*|filename:\s*|domain:\s*|"\s*\+\s*|\+\s*)$')

# Literals that read like words but are code: kept out of `loose` and `check`.
IGNORED = {
    "Shirox-Backup-\\(f.string(from: date)).shiroxbackup",  # a file name
    "MediaBrowser ",                                          # Jellyfin's auth header
    "Stremio", "Nuvio", "Vega", "SkyStream", "Mana",          # extension formats
    "HEVC (Dolby Vision)", "HE-AACv2", "Opus",                # codec names
    "Profile 1",                                              # compared against to spot the untouched first profile
}

# Names that stay as they are in every language.
PROPER_NOUNS = {"AniList", "MyAnimeList", "MAL", "Simkl", "Jellyfin", "TMDB", "TVDB", "Shirox", "MPV",
                "AirPlay", "Discord", "GitHub", "Seanime", "CloudStream", "Kitsu", "AniSkip", "iCloud"}

# A file's area: the key's first part.
AREAS = [
    ("SettingsView", "settings"), ("GeneralSettings", "settings"), ("AdvancedNetwork", "settings"),
    ("BackupSettings", "settings"), ("AppAppearance", "settings"), ("GooeyRefresh", "settings"), ("Services/Backup", "settings"), ("Views/Player", "player"),
    ("PlayerView", "player"), ("Views/Reader", "reader"), ("Views/Downloads", "downloads"),
    ("Views/Library", "library"), ("LibraryView", "library"), ("Views/Profile", "profile"),
    ("ProfilesView", "profile"), ("Views/Onboarding", "onboarding"), ("Views/Simkl", "simkl"),
    ("HomeView", "home"), ("UpcomingCalendar", "home"), ("Search", "search"), ("Browse", "search"),
    ("Jellyfin", "jellyfin"), ("Module", "modules"), ("Extension", "modules"),
    ("DetailView", "detail"), ("Detail", "detail"), ("StreamPicker", "detail"),
    ("EpisodeRow", "detail"), ("Views/Shared", "shared"), ("ViewModels", "shared"),
    ("Services", "shared"), ("Models", "shared"), ("ShiroxApp", "app"),
]


def area(path):
    for needle, name in AREAS:
        if needle in path:
            return name
    return "shared"


def words_only(text):
    return INTERPOLATION.sub("", text)


def is_key(text):
    """A literal that already is a key, arguments and all: "detail.download \\(count)"."""
    rest = words_only(text).strip()
    return bool(KEY.match(rest))


def is_ui_text(text, kind):
    """Whether a literal reads as words for a person, not an identifier, URL, path or format."""
    words = words_only(text)
    if len(re.findall(r"[A-Za-z]", words)) < 2 or words.strip() in PROPER_NOUNS or text in IGNORED:
        return False
    if is_key(text):
        return False
    # `return "…"` is often an identifier or a format: only text that starts like a sentence.
    if kind in ("returned", "case") and not re.match(r"[A-Z¿¡]", words.lstrip()):
        return False
    if re.search(r"[a-z]:\\\(", text):                    # "a:\(id)" style cache keys
        return False
    if re.fullmatch(r"[a-z0-9_.\-]+", text):              # identifiers, symbol names
        return False
    if re.fullmatch(r"[a-z]+(?:[A-Z][a-z0-9]*)+", text):  # camelCase identifiers
        return False
    # A URL or path on its own; a sentence that mentions one is still a sentence.
    if " " not in words.strip() and re.search(r"://|^/|\.(?:png|jpg|json|js|html|m3u8|mp4|swift)\b|^[a-z]+\.[a-z]+\.", text):
        return False
    if text.startswith(("%", "#", "$", "application/", "text/", "image/", "Bearer ", "Mozilla/")):
        return False
    if re.fullmatch(r"[A-Z0-9_\-]+", text) and len(text) > 1:
        return False                                      # codes and headers: "GET", "HLS"
    return True


def slug(text, limit=5):
    text = words_only(text).replace("&", " and ").replace("'", "").replace("’", "")
    words = re.findall(r"[A-Za-z0-9]+", text.lower())
    return "_".join(words[:limit]) or "text"


def swift_files(paths=None):
    if paths:
        for p in paths:
            p = os.path.abspath(p)
            if os.path.isdir(p):
                yield from sorted(glob.glob(os.path.join(p, "**", "*.swift"), recursive=True))
            elif p.endswith(".swift"):
                yield p
        return
    yield from sorted(glob.glob(os.path.join(SOURCES, "**", "*.swift"), recursive=True))


def scan(paths=None):
    """Every UI literal: hardcoded text and keys alike."""
    rows = []
    for path in swift_files(paths):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if line.strip().startswith("//") or SKIP_LINE.search(line):
                    continue
                seen = set()
                for kind, pattern in PATTERNS:
                    for match in pattern.finditer(line):
                        if match.start(1) in seen:
                            continue
                        seen.add(match.start(1))
                        rows.append({"text": match.group(1), "kind": kind, "file": rel, "line": number,
                                     "area": area(rel), "start": match.start(1) - 1,
                                     "end": match.end(1) + 1})
    return rows


def is_whole(text):
    """False for a literal the line pattern cut short at a quote inside an interpolation:
    `"episode\\(n == 1 ? "" : "s")"`. Those are done by hand."""
    return text.count("\\(") == len(INTERPOLATION.findall(text))


def hardcoded(rows):
    return [r for r in rows if is_ui_text(r["text"], r["kind"])]


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        # Xcode's own layout for .xcstrings, so its saves and ours don't fight.
        json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : "))
        f.write("\n")


def has_english(entry):
    en = entry.get("localizations", {}).get("en", {})
    if en.get("stringUnit", {}).get("value"):
        return True
    variations = en.get("variations", {})
    return any(v.get("stringUnit", {}).get("value")
               for kind in variations.values() for v in kind.values())


def keys_in_code(paths=None):
    """Every literal in the code that is a key, wherever it sits: a view's title, a
    String(localized:), a ternary handing one to LocalizedStringKey(…)."""
    literal = re.compile(LIT)
    found = []
    for path in swift_files(paths):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if line.strip().startswith("//"):
                    continue
                for match in literal.finditer(line):
                    text = match.group(1)
                    base = words_only(text).strip()
                    if is_key(text):
                        found.append((base, rel, number))
                    elif KEY.match(base.split(" ")[0]) and not is_whole(text):
                        found.append((text, rel, number))  # cut short: reported as not found
    return found


def catalog_bases(catalog):
    """Catalog keys without their argument specifiers."""
    return {k.split(" ")[0] for k in catalog.get("strings", {})}


def assign_keys(rows, taken):
    """A key per distinct text. `taken` maps keys already in use to their English text."""
    areas_by_text = defaultdict(set)
    for row in rows:
        areas_by_text[row["text"]].add(row["area"])
    by_text = {v: k for k, v in taken.items()}
    used = defaultdict(set)
    for k, v in taken.items():
        used[k].add(v)
    for row in sorted(rows, key=lambda r: (r["file"], r["line"])):
        text = row["text"]
        if text not in by_text:
            prefix = "common" if len(areas_by_text[text]) >= 3 else row["area"]
            key = base = f"{prefix}.{slug(text)}"
            n = 2
            while used[key] and text not in used[key]:
                key, n = f"{base}_{n}", n + 1
            used[key].add(text)
            by_text[text] = key
        row["key"] = by_text[text]
    return rows


# MARK: - Commands

def cmd_inventory(args):
    rows = assign_keys(hardcoded(scan(args or None)), load_json(TEXTS, {}))
    with open(INVENTORY, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["key", "text", "kind", "file", "line"], extrasaction="ignore")
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: (r["key"], r["file"], r["line"])))
    print(f"{len(rows)} hardcoded strings ({len({r['text'] for r in rows})} distinct) "
          f"→ {os.path.relpath(INVENTORY, ROOT)}")


def cmd_extract(args):
    """Rewrites each hardcoded literal in the given files as its key, and remembers the English."""
    if not args:
        sys.exit("extract: name the files or folders to extract")
    rows = hardcoded(scan(args))
    for row in rows:
        if not is_whole(row["text"]):
            print(f"  by hand: {row['file']}:{row['line']}: \"{row['text']}…")
    rewrite([r for r in rows if is_whole(r["text"])])


def unescape(text):
    return re.sub(r'\\(["\\nt\'])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def english(source, specifiers):
    """The catalog value: the source text with each interpolation replaced by its specifier."""
    parts = INTERPOLATION.split(source)
    if len(parts) - 1 != len(specifiers):
        return None
    positional = len(specifiers) > 1
    out = parts[0]
    for n, (spec, part) in enumerate(zip(specifiers, parts[1:]), 1):
        out += (spec.replace("%", f"%{n}$", 1) if positional else spec) + part
    return unescape(out)


def build_keys(build):
    """The keys a build's compiler found, from its .stringsdata files, with where they're used."""
    found = defaultdict(set)
    # Every platform built: some text only exists on a Mac or the TV.
    files = glob.glob(os.path.join(build, "**", "*.stringsdata"), recursive=True)
    for path in files:
        data = load_json(path, {})
        source = os.path.basename(data.get("source", ""))
        for entry in data.get("tables", {}).get("Localizable", []):
            found[entry["key"]].add(source)
    return found


def cmd_sync(args):
    build = args[args.index("--build") + 1] if "--build" in args else DEFAULT_BUILD
    texts = load_json(TEXTS, {})
    catalog = load_json(CATALOG, {"sourceLanguage": "en", "strings": {}, "version": "1.0"})
    strings = catalog.setdefault("strings", {})
    added, missing = 0, []
    in_code = {k for k, _, _ in keys_in_code()}
    for key, sources in sorted(build_keys(build).items()):
        base, *specifiers = key.split(" ")
        # Skips what an older build left behind for a key the code no longer has.
        if not KEY.match(base) or key in strings or base not in in_code:
            continue
        source = texts.get(base)
        value = english(source, specifiers) if source is not None else None
        if value is None:
            missing.append(key)
            continue
        strings[key] = {
            "comment": ", ".join(sorted(s.replace(".swift", "") for s in sources)),
            "localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}},
        }
        added += 1
    # Keys the compiler doesn't report (default arguments, LocalizedStringKey(…) of a variable):
    # the ones without arguments can still be added from what `extract` recorded.
    bases = catalog_bases(catalog)
    for key in sorted(in_code - bases):
        if key in texts and not INTERPOLATION.search(texts[key]):
            strings[key] = {"localizations": {"en": {"stringUnit": {"state": "translated",
                                                                    "value": unescape(texts[key])}}}}
            added += 1
    pruned = 0
    if "--prune" in args:
        for key in list(strings):
            if key.split(" ")[0] not in in_code:
                del strings[key]
                pruned += 1
    write_json(CATALOG, catalog)
    print(f"added {added} keys to the catalog" + (f", removed {pruned} unused" if pruned else ""))
    for key in missing:
        print(f"  no English for {key!r}: add it to the catalog by hand")


def cmd_check(args):
    rows = scan(args or None)
    catalog = load_json(CATALOG, {})
    bases = catalog_bases(catalog)
    problems = []
    for row in hardcoded(rows):
        problems.append(f"{row['file']}:{row['line']}: hardcoded text \"{row['text']}\": use a key")
    used = set(keys_in_code(args or None))
    for key, rel, number in sorted(used):
        if key not in bases:
            problems.append(f"{rel}:{number}: key \"{key}\" isn't in Localizable.xcstrings")
    for key, entry in catalog.get("strings", {}).items():
        if not has_english(entry):
            problems.append(f"Shirox/Localizable.xcstrings: \"{key}\" has no English text")
    if not args:
        in_code = {k for k, _, _ in used}
        stale = sorted(b for b in bases if b not in in_code)
        for key in stale:
            print(f"note: \"{key}\" is in the catalog but not used in code")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} i18n problems. See the top of scripts/i18n/i18n.py.")
        sys.exit(1)
    print("i18n: all UI text goes through the string catalog")


def cmd_loose(args):
    """Text-like literals outside the known UI calls: arguments to the app's own helpers, mostly.
    For review by hand; some are names or formats that are fine as they are."""
    covered = {(r["file"], r["line"], r["start"]) for r in scan(args or None)}
    literal = re.compile(LIT)
    count = 0
    for path in swift_files(args or None):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if line.strip().startswith("//") or SKIP_LINE.search(line):
                    continue
                for match in literal.finditer(line):
                    text = match.group(1)
                    if (rel, number, match.start()) in covered or "String(localized:" in line[:match.start()][-20:]:
                        continue
                    before = line[:match.start()]
                    # `"key": value` and `["key"]` are lookups; ` : ` after a literal is a ternary's.
                    if NOT_UI_CONTEXT.search(before) or line[match.end():].startswith((":", "]")):
                        continue
                    if is_ui_text(text, "returned"):
                        print(f"{rel}:{number}: \"{text}\"")
                        count += 1
    print(f"{count} literals to look at")


def cmd_list(args):
    """Hardcoded strings of the given kinds (view, modifier, argument, returned, case), by file."""
    kinds = set(args) or {k for k, _ in PATTERNS}
    current = None
    for row in sorted(hardcoded(scan()), key=lambda r: (r["file"], r["line"])):
        if row["kind"] not in kinds:
            continue
        if row["file"] != current:
            current = row["file"]
            print(f"## {current}")
        print(f"  {row['line']}: {row['text']}")


def cmd_dedupe(args):
    """One key per sentence: keys whose English differs only in its arguments' code
    ("Delete \\(a.count)", "Delete \\(n)") merge into the first, in code and catalog."""
    texts = load_json(TEXTS, {})
    catalog = load_json(CATALOG, {"strings": {}})
    strings = catalog["strings"]
    groups = defaultdict(list)
    for key, source in texts.items():
        groups[(key.split(".")[0], INTERPOLATION.sub("\\(_)", source))].append(key)
    renames = {}
    for keys in groups.values():
        keys.sort(key=lambda k: (bool(re.search(r"_\d+$", k)), len(k), k))
        for other in keys[1:]:
            renames[other] = keys[0]
    if not renames:
        print("no duplicate keys")
        return
    pattern = re.compile(r'"(' + "|".join(map(re.escape, sorted(renames, key=len, reverse=True))) + r')(?=[ "])')
    for path in swift_files():
        with open(path, encoding="utf-8") as f:
            code = f.read()
        new = pattern.sub(lambda m: '"' + renames[m.group(1)], code)
        if new != code:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
    for key in list(strings):
        base, _, specifiers = key.partition(" ")
        if base in renames:
            entry = strings.pop(key)
            target = renames[base] + (" " + specifiers if specifiers else "")
            strings.setdefault(target, entry)
    for old in renames:
        texts.pop(old, None)
    write_json(TEXTS, dict(sorted(texts.items())))
    write_json(CATALOG, catalog)
    print(f"merged {len(renames)} keys into others")


def cmd_pick(args):
    """Turns hand-picked literals from `loose` into keys. Reads lines of `path:line` (every
    text-like literal on that line) or `path:line:text` (just that one) from the file given."""
    if not args:
        sys.exit("pick: name a file of path:line[:text] lines")
    wanted = defaultdict(list)
    with open(args[0], encoding="utf-8") as f:
        for entry in f.read().splitlines():
            entry = entry.strip()
            if not entry or entry.startswith("#"):
                continue
            path, line, *text = entry.split(":", 2)
            wanted[(path, int(line))].append(text[0] if text else None)
    literal = re.compile(LIT)
    rows = []
    for (rel, number), texts_wanted in wanted.items():
        with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
            line = f.read().split("\n")[number - 1]
        for match in literal.finditer(line):
            text = match.group(1)
            if (None in texts_wanted and is_ui_text(text, "returned")) or text in texts_wanted:
                if not is_whole(text):
                    print(f"  by hand: {rel}:{number}: \"{text}…")
                    continue
                rows.append({"text": text, "kind": "argument", "file": rel, "line": number,
                             "area": area(rel), "start": match.start(), "end": match.end()})
    rewrite(rows)


def rewrite(rows):
    """Replaces each row's literal with its key, and remembers the English."""
    texts = load_json(TEXTS, {})
    rows = assign_keys(rows, texts)
    by_file = defaultdict(list)
    for row in rows:
        by_file[row["file"]].append(row)
    for rel, file_rows in by_file.items():
        path = os.path.join(ROOT, rel)
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        # Right to left within a line, so earlier columns stay where they were.
        for row in sorted(file_rows, key=lambda r: (r["line"], -r["start"])):
            i = row["line"] - 1
            line = lines[i]
            literal = line[row["start"]:row["end"]]
            assert literal == f'"{row["text"]}"', (rel, row["line"], literal)
            args_in = " ".join(INTERPOLATION.findall(row["text"]))
            keyed = f'"{row["key"]}{" " + args_in if args_in else ""}"'
            if row["kind"] not in ("view", "modifier"):
                keyed = f"String(localized: {keyed})"
            lines[i] = line[:row["start"]] + keyed + line[row["end"]:]
            texts[row["key"]] = row["text"]
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
    write_json(TEXTS, dict(sorted(texts.items())))
    print(f"extracted {len(rows)} strings in {len(by_file)} files; run a build, then `sync`")


def cmd_rename(args):
    """Renames keys in code, catalog and texts.json at once, from a file of `old new` lines.
    One pass, so two keys can swap names; several onto one merges them, keeping the
    entry already there or else the first."""
    if not args:
        sys.exit("rename: name a file of `old new` lines")
    with open(args[0], encoding="utf-8") as f:
        renames = dict(line.split() for line in f if line.strip() and not line.startswith("#"))
    bad = [n for n in renames.values() if not KEY.match(n)]
    if bad:
        sys.exit(f"rename: not keys: {bad}")
    pattern = re.compile(r'"(' + "|".join(map(re.escape, sorted(renames, key=len, reverse=True))) + r')(?=[ "])')
    changed = 0
    for path in swift_files():
        with open(path, encoding="utf-8") as f:
            code = f.read()
        new = pattern.sub(lambda m: '"' + renames[m.group(1)], code)
        if new != code:
            changed += 1
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
    catalog = load_json(CATALOG, {"strings": {}})
    # Keys that stay come first, so a key renamed onto one that exists merges into it.
    strings = {}
    items = sorted(catalog["strings"].items(), key=lambda kv: kv[0].partition(" ")[0] in renames)
    for key, entry in items:
        base, _, specifiers = key.partition(" ")
        strings.setdefault(renames.get(base, base) + (" " + specifiers if specifiers else ""), entry)
    catalog["strings"] = strings
    write_json(CATALOG, catalog)
    texts = load_json(TEXTS, {})
    write_json(TEXTS, dict(sorted((renames.get(k, k), v) for k, v in texts.items())))
    print(f"renamed {len(renames)} keys in {changed} files")


def cmd_import(args):
    """Adds a language's text to the catalog from a JSON file of key -> text, or for plurals
    key -> {"one": …, "other": …}: `import de de.json`. Checks every format specifier made it."""
    if len(args) != 2:
        sys.exit("import: give a language code and a JSON file")
    language, path = args
    translated = load_json(path, None)
    if translated is None:
        sys.exit(f"import: can't read {path}")
    catalog = load_json(CATALOG, {"strings": {}})
    strings = catalog["strings"]
    spec = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|lu|llu|@|d|u|f|lf|s)")
    norm = lambda v: sorted(re.sub(r"\d+\$", "", m) for m in spec.findall(v))
    unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
    problems, imported = [], 0
    for key, value in translated.items():
        entry = strings.get(key)
        if entry is None:
            problems.append(f"{key}: not in the catalog")
            continue
        english = entry["localizations"]["en"]
        if isinstance(value, dict):
            forms = english.get("variations", {}).get("plural", {})
            for form, text in value.items():
                source = forms.get(form, forms.get("other", {})).get("stringUnit", {}).get("value", "")
                if norm(text) != norm(source):
                    problems.append(f"{key} [{form}]: specifiers differ from the English")
            entry["localizations"][language] = {"variations": {"plural": {f: unit(t) for f, t in value.items()}}}
        else:
            if norm(value) != norm(english.get("stringUnit", {}).get("value", "")):
                problems.append(f"{key}: specifiers differ from the English")
            entry["localizations"][language] = unit(value)
        imported += 1
    missing = [k for k in strings if k not in translated and language not in strings[k]["localizations"]]
    write_json(CATALOG, catalog)
    print(f"imported {imported} {language} strings; {len(missing)} keys still without {language}")
    for problem in problems:
        print("  " + problem)


COMMANDS = {"import": cmd_import, "rename": cmd_rename, "pick": cmd_pick, "dedupe": cmd_dedupe, "list": cmd_list, "loose": cmd_loose, "check": cmd_check, "inventory": cmd_inventory, "extract": cmd_extract, "sync": cmd_sync}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
