#!/usr/bin/env bash
# Regenerates Shirox/Resources/adult_hosts.txt from a porn-only host list.
# Porn-only (NOT the unified StevenBlack list) so we don't block ad/malware/CDN hosts
# that legitimate streaming modules may rely on.
#
# Written as one bare lowercase host per line, sorted: no `0.0.0.0 ` prefix, no comments
# from the source, no duplicates, and no host whose parent domain is listed too, since
# HostBlocklist blocks every subdomain of a listed host anyway.
set -euo pipefail
SRC="https://raw.githubusercontent.com/Sinfonietta/hostfiles/master/pornography-hosts"
OUT="$(dirname "$0")/../Shirox/Resources/adult_hosts.txt"
mkdir -p "$(dirname "$OUT")"
{
  echo "# Adult host blocklist for Shirox — porn-only, one host per line."
  echo "# Source: $SRC"
  echo "# Regenerate with scripts/fetch_adult_hosts.sh"
  curl -fsSL "$SRC" | LC_ALL=C awk '
    {
      sub(/#.*/, "")
      if (NF == 0) next
      host = tolower($NF)
      if (host == "localhost" || index(host, ".") == 0) next
      hosts[host] = 1
    }
    END {
      for (host in hosts) {
        rest = host
        covered = 0
        # Drop the first label while at least two remain: a listed parent covers this host.
        while ((dot = index(rest, ".")) > 0) {
          rest = substr(rest, dot + 1)
          if (index(rest, ".") == 0) break
          if (rest in hosts) { covered = 1; break }
        }
        if (!covered) print host
      }
    }' | LC_ALL=C sort
} > "$OUT"
echo "Wrote $(grep -vc '^#' "$OUT") hosts ($(wc -c < "$OUT" | tr -d ' ') bytes) to $OUT"
