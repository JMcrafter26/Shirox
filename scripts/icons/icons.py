#!/usr/bin/env python3
"""The SF Symbols Shirox uses, as the list icon packs are made against.

    python3 -I scripts/icons/icons.py update   # rewrites iconpacks/icons.json (macOS: needs the
                                               # system's SF Symbols list); bumps its version when
                                               # the set of icons changes
    python3 -I scripts/icons/icons.py check    # fails if the code uses a symbol icons.json lacks
    python3 -I scripts/icons/icons.py packs    # checks every pack in iconpacks/ against icons.json

An icon is any string literal in the Swift sources that names a real SF Symbol, wherever it sits:
`Image(systemName:)`, `Label(…, systemImage:)`, an enum's `icon` property, either side of a
ternary. Names put together at runtime ("\\(name).fill") can't be found this way; write the
full names out as literals instead.

A pack is a folder in iconpacks/ with a pack.json and its SVG files:

    { "name": "Font Awesome", "author": "Fonticons, Inc.", "license": "CC BY 4.0",
      "url": "https://fontawesome.com", "iconsVersion": 3, "packVersion": 1,
      "icons": { "house.fill": "house.svg", … } }

`iconsVersion` is the icons.json version the pack was made for. The app loads a pack only when
it matches the version it ships with, so a pack missing new icons is never half applied.
"""
import glob
import json
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SOURCES = os.path.join(ROOT, "Shirox")
PACKS = os.path.join(ROOT, "iconpacks")
MANIFEST = os.path.join(PACKS, "icons.json")
SF_SYMBOLS = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"

LITERAL = re.compile(r'"([a-z0-9]+(?:\.[a-z0-9]+)*)"')
# Where a literal is an icon whatever it names: for `check`, which also runs without the
# system's symbol list (CI on Linux).
ICON_CONTEXT = re.compile(r'(?:systemName|systemImage|icon|symbol)\s*:\s*"([^"]+)"')


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def swift_lines():
    for path in sorted(glob.glob(os.path.join(SOURCES, "**", "*.swift"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                if not line.strip().startswith("//"):
                    yield os.path.relpath(path, ROOT), number, line


def system_symbols():
    if not os.path.exists(SF_SYMBOLS):
        sys.exit("update needs macOS: the SF Symbols list comes from CoreGlyphs.bundle")
    with open(SF_SYMBOLS, "rb") as f:
        return set(plistlib.load(f)["symbols"])


# Declarations whose body names icons: `var icon: String`, `func symbol(for:)`, `systemImage`.
ICON_DECLARATION = re.compile(r'\b(?:var|func|let)\s+\w*(?:icon|Icon|symbol|Symbol|systemImage|systemName)\w*')
DECLARATION = re.compile(r'^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|override)\s+)*(?:var|func|let|init|struct|enum|class)\b')


def used_icons(known):
    """Names with a dot are icons wherever they are ("house.fill" is nothing else). A bare word
    ("house", but also "left" or "case") counts only where icons are named: an icon parameter,
    or inside a property or function whose name says it returns one."""
    found = set()
    in_icon_body = False
    current = None
    for rel, _, line in swift_lines():
        if rel != current:
            current, in_icon_body = rel, False
        if DECLARATION.match(line):
            in_icon_body = bool(ICON_DECLARATION.search(line))
        context = in_icon_body or ICON_CONTEXT.search(line) or "systemName" in line or "systemImage" in line
        for match in LITERAL.finditer(line):
            name = match.group(1)
            if name in known and ("." in name or context):
                found.add(name)
    return sorted(found)


def cmd_update(_):
    icons = used_icons(system_symbols())
    manifest = load_json(MANIFEST, {"version": 0, "icons": []})
    if icons != manifest.get("icons"):
        added = sorted(set(icons) - set(manifest.get("icons", [])))
        removed = sorted(set(manifest.get("icons", [])) - set(icons))
        manifest = {"version": manifest.get("version", 0) + 1, "icons": icons}
        write_json(MANIFEST, manifest)
        print(f"icons.json is version {manifest['version']}: {len(icons)} icons "
              f"(+{len(added)} -{len(removed)})")
        for name in added:
            print(f"  + {name}")
        for name in removed:
            print(f"  - {name}")
        print("Packs made for the previous version won't load until they're updated.")
    else:
        print(f"icons.json is up to date: version {manifest['version']}, {len(icons)} icons")


def cmd_check(_):
    manifest = load_json(MANIFEST, None)
    if manifest is None:
        sys.exit("iconpacks/icons.json is missing: run `icons.py update`")
    listed = set(manifest["icons"])
    problems = []
    if os.path.exists(SF_SYMBOLS):
        missing = sorted(set(used_icons(system_symbols())) - listed)
        problems += [f"icon \"{name}\" isn't in iconpacks/icons.json" for name in missing]
    for rel, number, line in swift_lines():
        for match in ICON_CONTEXT.finditer(line):
            name = match.group(1)
            if "\\(" in name:
                problems.append(f"{rel}:{number}: icon name built at runtime: write each one out")
            elif LITERAL.fullmatch(f'"{name}"') and name not in listed and "." in name:
                problems.append(f"{rel}:{number}: icon \"{name}\" isn't in iconpacks/icons.json")
    for problem in sorted(set(problems)):
        print(problem)
    if problems:
        print("\nRun `python3 -I scripts/icons/icons.py update` and bump the packs.")
        sys.exit(1)
    print(f"icons: all {len(listed)} icons are listed (version {manifest['version']})")


def cmd_packs(_):
    manifest = load_json(MANIFEST, {"version": 0, "icons": []})
    failed = False
    for path in sorted(glob.glob(os.path.join(PACKS, "*", "pack.json"))):
        pack = load_json(path, {})
        folder = os.path.dirname(path)
        name = os.path.relpath(folder, PACKS)
        problems = []
        if pack.get("iconsVersion") != manifest["version"]:
            problems.append(f"made for icons version {pack.get('iconsVersion')}, "
                            f"the app is on {manifest['version']}")
        icons = pack.get("icons", {})
        problems += [f"no icon for {n}" for n in manifest["icons"] if n not in icons]
        problems += [f"{n}: {f} is missing" for n, f in icons.items()
                     if not os.path.exists(os.path.join(folder, "icons", f))]
        print(f"{name}: {'ok' if not problems else str(len(problems)) + ' problems'}")
        for problem in problems[:20]:
            print(f"  {problem}")
        failed |= bool(problems)
    sys.exit(1 if failed else 0)


COMMANDS = {"update": cmd_update, "check": cmd_check, "packs": cmd_packs}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
