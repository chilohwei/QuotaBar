#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK_FILE="$ROOT_DIR/Casks/quotabar.rb"
REPO_OWNER="${REPO_OWNER:-chilohwei}"
REPO_NAME="${REPO_NAME:-QuotaBar}"

usage() {
    cat <<USAGE
Usage: scripts/update_homebrew_cask.sh <version> [--allow-local-fallback]

Updates Casks/quotabar.rb to point at:
  dist/releases/QuotaBar-<version>-universal.dmg

Behavior:
  - Computes local SHA256 from dist/releases when available.
  - Falls back to the GitHub release asset when running in CI without local DMG outputs.
  - By default, requires GitHub release asset to be reachable and uses its SHA256.
  - Use --allow-local-fallback to write local SHA when release asset is not reachable.
USAGE
}

ALLOW_LOCAL_FALLBACK=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-local-fallback)
            ALLOW_LOCAL_FALLBACK=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            VERSION="$1"
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    usage
    exit 1
fi

DMG_FILE="$ROOT_DIR/dist/releases/QuotaBar-$VERSION-universal.dmg"
RELEASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/QuotaBar-${VERSION}-universal.dmg"
TMP_REMOTE_FILE="${TMPDIR:-/tmp}/quotabar-release-${VERSION}-$$.dmg"
SHA256=""
LOCAL_SHA256=""

if [[ -f "$DMG_FILE" ]]; then
    LOCAL_SHA256="$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')"
    SHA256="$LOCAL_SHA256"
else
    echo "Notice: local universal DMG not found, using release asset if available: $DMG_FILE"
fi

cleanup() {
    rm -f "$TMP_REMOTE_FILE"
}
trap cleanup EXIT

if curl -Lf --retry 2 --retry-delay 1 -o "$TMP_REMOTE_FILE" "$RELEASE_URL" >/dev/null 2>&1; then
    REMOTE_SHA256="$(shasum -a 256 "$TMP_REMOTE_FILE" | awk '{print $1}')"
    if [[ -n "$LOCAL_SHA256" && "$REMOTE_SHA256" != "$LOCAL_SHA256" ]]; then
        echo "Notice: local SHA differs from released asset SHA."
        echo "  local : $LOCAL_SHA256"
        echo "  remote: $REMOTE_SHA256"
        echo "Using remote SHA to keep Homebrew install consistent with GitHub release."
    fi
    SHA256="$REMOTE_SHA256"
else
    if [[ "$ALLOW_LOCAL_FALLBACK" == true && -n "$LOCAL_SHA256" ]]; then
        echo "Notice: release asset not reachable yet, using local SHA (--allow-local-fallback enabled)."
    else
        echo "Release asset not reachable: $RELEASE_URL" >&2
        echo "Refusing to update cask with local SHA to avoid Homebrew checksum mismatch." >&2
        echo "If you intentionally want local fallback, rerun with --allow-local-fallback." >&2
        exit 1
    fi
fi

python3 - "$CASK_FILE" "$VERSION" "$SHA256" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]

text = path.read_text()
text = re.sub(r'version "[^"]+"', f'version "{version}"', text)
text = re.sub(r'sha256 "[0-9a-f]{64}"', f'sha256 "{sha256}"', text)
path.write_text(text)
PY

echo "Updated $CASK_FILE"
echo "version: $VERSION"
echo "sha256: $SHA256"
