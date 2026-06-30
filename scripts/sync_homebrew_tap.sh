#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CASK_FILE="$ROOT_DIR/Casks/quotabar.rb"
TAP_REPO="${TAP_REPO:-chilohwei/homebrew-quotabar}"
TAP_BRANCH="${TAP_BRANCH:-main}"
TOKEN="${HOMEBREW_TAP_GITHUB_TOKEN:-}"

usage() {
    cat <<USAGE
Usage: scripts/sync_homebrew_tap.sh <version>

Copies Casks/quotabar.rb into the standalone Homebrew tap repository and pushes
the change when the cask differs from the tap copy.

Environment:
  HOMEBREW_TAP_GITHUB_TOKEN  Required GitHub token with write access to TAP_REPO
  TAP_REPO                   Optional tap repo slug (default: chilohwei/homebrew-quotabar)
  TAP_BRANCH                 Optional tap branch (default: main)
USAGE
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

VERSION="$1"

if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][A-Za-z0-9._-]+)?$ ]]; then
    echo "Invalid version: $VERSION" >&2
    exit 1
fi

if [[ ! "$TAP_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid TAP_REPO: $TAP_REPO" >&2
    exit 1
fi

if [[ ! "$TAP_BRANCH" =~ ^[A-Za-z0-9._/-]+$ || "$TAP_BRANCH" == -* ]]; then
    echo "Invalid TAP_BRANCH: $TAP_BRANCH" >&2
    exit 1
fi

if [[ ! -f "$CASK_FILE" ]]; then
    echo "Missing cask file: $CASK_FILE" >&2
    exit 1
fi

if [[ -z "$TOKEN" ]]; then
    echo "Missing HOMEBREW_TAP_GITHUB_TOKEN." >&2
    exit 1
fi

OLD_UMASK="$(umask)"
umask 077
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quotabar-tap-sync.XXXXXX")"
umask "$OLD_UMASK"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TOKEN_FILE="$TMP_DIR/github-token"
ASKPASS_FILE="$TMP_DIR/git-askpass.sh"
printf '%s' "$TOKEN" > "$TOKEN_FILE"
cat > "$ASKPASS_FILE" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *Password*) cat "$GIT_PASSWORD_FILE" ;;
    *) printf '\n' ;;
esac
ASKPASS
chmod 700 "$ASKPASS_FILE"

export GIT_ASKPASS="$ASKPASS_FILE"
export GIT_PASSWORD_FILE="$TOKEN_FILE"
export GIT_TERMINAL_PROMPT=0

TAP_DIR="$TMP_DIR/homebrew-quotabar"
git clone "https://github.com/${TAP_REPO}.git" "$TAP_DIR"
git -C "$TAP_DIR" checkout "$TAP_BRANCH"

mkdir -p "$TAP_DIR/Casks"
cp "$CASK_FILE" "$TAP_DIR/Casks/quotabar.rb"

if git -C "$TAP_DIR" diff --quiet -- Casks/quotabar.rb; then
    echo "Tap already up to date for v$VERSION."
    exit 0
fi

git -C "$TAP_DIR" config user.name "github-actions[bot]"
git -C "$TAP_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$TAP_DIR" add Casks/quotabar.rb
git -C "$TAP_DIR" commit -m "chore: update cask for v$VERSION"
git -C "$TAP_DIR" push origin "$TAP_BRANCH"

echo "Synced Homebrew tap ${TAP_REPO}@${TAP_BRANCH} to v$VERSION."
