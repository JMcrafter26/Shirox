#!/usr/bin/env python3
"""Adds strings to the catalog by hand: `add_strings.py FILE.json`, where the file maps a full
catalog key (with its specifiers, "settings.update_to_version %lld") to {"en": …, "de": …, …}."""
import json
import os
import sys

CATALOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Shirox", "Localizable.xcstrings")

with open(sys.argv[1], encoding="utf-8") as f:
    new = json.load(f)
with open(CATALOG, encoding="utf-8") as f:
    catalog = json.load(f)
for key, languages in new.items():
    entry = catalog["strings"].setdefault(key, {"localizations": {}})
    for language, value in languages.items():
        entry["localizations"][language] = {"stringUnit": {"state": "translated", "value": value}}
with open(CATALOG, "w", encoding="utf-8") as f:
    json.dump(catalog, f, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : "))
    f.write("\n")
print(f"added or updated {len(new)} keys")
