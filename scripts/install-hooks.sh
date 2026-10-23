#!/usr/bin/env bash
# Points git at the repo's hooks in .githooks (commit message rules, Semgrep on staged files).

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
chmod +x "$root"/.githooks/* "$root/scripts/check-commit-msg.sh"
git -C "$root" config core.hooksPath .githooks
echo "Git hooks enabled from .githooks"
