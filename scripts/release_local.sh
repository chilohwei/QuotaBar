#!/usr/bin/env bash
set -euo pipefail

# Local signed + notarized release for QuotaBar.
#
# Builds on THIS Mac using the Developer ID identity in your login keychain, notarizes with your
# local Apple credentials, then uploads the notarized DMGs to a GitHub Release and updates the
# Homebrew cask. Signing/notarization credentials never leave this machine and are never committed.
#
# One-time prerequisites:
#   1. A "Developer ID Application: … (TEAMID)" identity in your login keychain:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   2. Notarization credentials — RECOMMENDED: store a notarytool profile once, then export its name:
#        xcrun notarytool store-credentials QuotaBarNotary \
#          --key ~/keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
#        export NOTARY_KEYCHAIN_PROFILE=QuotaBarNotary
#      OR export an API key path instead:
#        export AC_API_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8 AC_API_KEY_ID=… AC_API_ISSUER_ID=…
#   3. GitHub CLI authenticated:  gh auth status
#
# Usage:
#   scripts/release_local.sh --version 1.3.2 [--arch all|arm64|x86_64|universal]
#                            [--draft] [--no-cask] [--notes-file FILE] [--yes] [--dry-run]

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="all"
VERSION=""
DRAFT=false
UPDATE_CASK=true
NOTES_FILE=""
ASSUME_YES=false
DRY_RUN=false

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/release_local.sh --version X.Y.Z [options]
  --arch <all|arm64|x86_64|universal>  architectures to build (default: all)
  --draft            create the GitHub release as a draft (skips cask update)
  --no-cask          do not update the Homebrew cask/tap
  --notes-file FILE  release notes file (default: auto-generated)
  --yes, -y          skip the confirmation prompt
  --dry-run          run preflight checks and stop before building
See the header of this script for one-time credential setup.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        --draft) DRAFT=true; shift ;;
        --no-cask) UPDATE_CASK=false; shift ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$VERSION" ]] || { usage >&2; die "--version X.Y.Z is required."; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9._-]+)?$ ]] || die "invalid version: $VERSION"
case "$ARCH" in all|arm64|x86_64|universal) ;; *) die "invalid --arch: $ARCH" ;; esac

command -v gh >/dev/null 2>&1 || die "GitHub CLI 'gh' not found. Install it and run 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run 'gh auth login'."

# Resolve the Developer ID signing identity from the keychain unless one is pinned via env.
if [[ -z "${SIGNING_IDENTITY:-}" || "$SIGNING_IDENTITY" == "-" ]]; then
    ids="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE 'Developer ID Application: [^"]+' | sort -u || true)"
    id_count="$(printf '%s\n' "$ids" | grep -c . || true)"
    [[ "$id_count" -ge 1 ]] \
        || die "no 'Developer ID Application' identity in the keychain — create/import one first (docs/signing-and-notarization.md)."
    [[ "$id_count" -eq 1 ]] \
        || die "multiple Developer ID identities found; set SIGNING_IDENTITY to the exact one."
    SIGNING_IDENTITY="$(printf '%s\n' "$ids" | head -1)"
fi
export SIGNING_IDENTITY

# Verify notarization credentials are present (build_macos_app.sh enforces the details).
if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" ]] \
        || { [[ -z "${AC_API_KEY_PATH:-}" ]] && [[ -z "${AC_API_KEY_P8_BASE64:-}" ]]; }; then
        die "notarization credentials missing — set NOTARY_KEYCHAIN_PROFILE, or AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_PATH."
    fi
fi
export NOTARIZE=true

# If the release/tag does not exist yet, require the version to be ahead of the latest remote tag.
release_exists=false
if gh release view "v$VERSION" >/dev/null 2>&1; then
    release_exists=true
fi
if [[ "$release_exists" != true ]]; then
    scripts/release_version.sh check "$VERSION" >/dev/null \
        || die "version $VERSION is not ahead of the latest remote release tag."
fi

# The tag is created server-side at the branch's remote HEAD, so local must be pushed and clean.
if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree is dirty — commit or stash before releasing."
fi
current_branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == "main" ]] || echo "warning: releasing from '$current_branch', not 'main'." >&2
git fetch origin "$current_branch" >/dev/null 2>&1 || true
if [[ -n "$(git rev-list "origin/${current_branch}..HEAD" 2>/dev/null || true)" ]]; then
    die "local ${current_branch} has unpushed commits — push them so the release tag matches."
fi

notary_desc="App Store Connect API key"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then notary_desc="keychain profile '${NOTARY_KEYCHAIN_PROFILE}'"; fi
cask_desc="+ Homebrew cask"
if [[ "$UPDATE_CASK" != true || "$DRAFT" == true ]]; then cask_desc="(cask update skipped)"; fi
draft_desc=""
if [[ "$DRAFT" == true ]]; then draft_desc="draft "; fi

cat >&2 <<PLAN

QuotaBar local release plan
  version : v${VERSION}   (${release_exists:+re-upload to existing release}${release_exists:-new release})
  arch    : ${ARCH}
  identity: ${SIGNING_IDENTITY}
  notary  : ${notary_desc}
  publish : ${draft_desc}GitHub Release  ${cask_desc}
PLAN

if [[ "$DRY_RUN" == true ]]; then
    echo "dry-run: preflight passed, stopping before build." >&2
    exit 0
fi
if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Proceed with build + notarize + publish? [y/N] " ans || true
    [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]] || die "aborted."
fi

# 1) Build + sign (Developer ID) + notarize + staple. Version already checked above.
echo "==> building, signing and notarizing v${VERSION} (${ARCH})..." >&2
QUOTABAR_SKIP_REMOTE_VERSION_CHECK=true \
    scripts/build_macos_app.sh --arch "$ARCH" --version "$VERSION"

# 2) Collect the notarized DMGs and their checksums.
shopt -s nullglob
assets=(dist/releases/QuotaBar-"$VERSION"-*.dmg dist/releases/QuotaBar-"$VERSION"-*.dmg.sha256)
shopt -u nullglob
[[ ${#assets[@]} -ge 1 ]] || die "no build artifacts found in dist/releases for v${VERSION}."

# 3) Create or update the GitHub Release.
if [[ "$release_exists" == true ]]; then
    echo "==> uploading assets to existing release v${VERSION}..." >&2
    gh release upload "v$VERSION" "${assets[@]}" --clobber
else
    echo "==> creating GitHub Release v${VERSION}..." >&2
    create_args=(--title "v$VERSION" --target "$current_branch")
    if [[ -n "$NOTES_FILE" ]]; then
        create_args+=(--notes-file "$NOTES_FILE")
    else
        create_args+=(--generate-notes)
    fi
    if [[ "$DRAFT" == true ]]; then create_args+=(--draft); fi
    gh release create "v$VERSION" "${assets[@]}" "${create_args[@]}"
fi

# 4) Update the Homebrew cask + tap from the published universal asset.
if [[ "$UPDATE_CASK" == true && "$DRAFT" != true ]]; then
    echo "==> updating Homebrew cask..." >&2
    scripts/update_homebrew_cask.sh "$VERSION"
    if ! git diff --quiet -- Casks/quotabar.rb; then
        git add Casks/quotabar.rb
        git commit -m "Update cask for v$VERSION"
        git push origin "$current_branch"
    fi
    tap_token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$tap_token" ]]; then
        HOMEBREW_TAP_GITHUB_TOKEN="$tap_token" scripts/sync_homebrew_tap.sh "$VERSION" \
            || echo "warning: Homebrew tap sync failed — check push access to the tap repo." >&2
    fi
elif [[ "$DRAFT" == true ]]; then
    echo "note: draft release — publish it, then run 'scripts/update_homebrew_cask.sh $VERSION'." >&2
fi

echo "Done: https://github.com/chilohwei/QuotaBar/releases/tag/v${VERSION}" >&2
