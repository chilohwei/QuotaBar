#!/usr/bin/env bash
set -euo pipefail

# Enforces the mechanical house style declared in .editorconfig on Swift sources:
#   - space indentation only (no leading tabs)
#   - no trailing whitespace
#   - every file ends with a newline
#
# The codebase already satisfies these; this guard turns .editorconfig (which only
# editors honour) into a CI-enforced invariant so regressions cannot slip in. It
# deliberately does NOT impose a full formatter (e.g. swift-format), whose default
# wrapping and brace conventions diverge from this project's established style.
#
# Run locally with: bash scripts/check_style.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

target_dirs=(Sources Tests)
status=0
checked=0

while IFS= read -r -d '' file; do
    checked=$((checked + 1))
    problems="$(
        awk '
            /^ *\t/   { print "  line " NR ": tab used for indentation" }
            /[ \t]+$/ { print "  line " NR ": trailing whitespace" }
        ' "$file"
    )"
    if [ -n "$(tail -c1 "$file")" ]; then
        problems="${problems:+$problems$'\n'}  missing final newline"
    fi
    if [ -n "$problems" ]; then
        echo "✗ $file"
        printf '%s\n' "$problems"
        status=1
    fi
done < <(find "${target_dirs[@]}" -name '*.swift' -print0)

if [ "$status" -eq 0 ]; then
    echo "Style hygiene OK: ${checked} Swift files checked."
fi
exit "$status"
