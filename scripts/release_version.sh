#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${REMOTE:-origin}"
BUMP="patch"
EXCLUDE_VERSION=""

usage() {
    cat <<USAGE
Usage:
  scripts/release_version.sh current
  scripts/release_version.sh latest [--remote origin] [--exclude-version 1.2.3]
  scripts/release_version.sh next [--remote origin] [--bump patch|minor|major]
  scripts/release_version.sh check <version> [--remote origin] [--exclude-version 1.2.3]

Reads stable SemVer tags from the GitHub remote (vX.Y.Z) and enforces release
version ordering against the remote source of truth.
USAGE
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

COMMAND="$1"
shift

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)
            REMOTE="${2:-}"
            if [[ -z "$REMOTE" ]]; then
                echo "Missing value for --remote" >&2
                exit 1
            fi
            shift 2
            ;;
        --bump)
            BUMP="${2:-}"
            shift 2
            ;;
        --exclude-version)
            EXCLUDE_VERSION="${2:-}"
            shift 2
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
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

normalize_version() {
    local raw="$1"
    raw="${raw#refs/tags/}"
    raw="${raw#v}"
    printf '%s\n' "$raw"
}

is_stable_semver() {
    [[ "$1" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]
}

version_key() {
    local version="$1"
    IFS=. read -r major minor patch <<<"$version"
    printf '%09d.%09d.%09d\n' "$major" "$minor" "$patch"
}

compare_versions() {
    local lhs="$1"
    local rhs="$2"
    local lhs_key rhs_key
    lhs_key="$(version_key "$lhs")"
    rhs_key="$(version_key "$rhs")"
    if [[ "$lhs_key" > "$rhs_key" ]]; then
        printf '1\n'
    elif [[ "$lhs_key" < "$rhs_key" ]]; then
        printf -- '-1\n'
    else
        printf '0\n'
    fi
}

remote_versions() {
    git ls-remote --tags --refs "$REMOTE" 'v*' \
        | awk '{print $2}' \
        | while read -r ref; do
            version="$(normalize_version "$ref")"
            if is_stable_semver "$version" && [[ "$version" != "$EXCLUDE_VERSION" ]]; then
                printf '%s\n' "$version"
            fi
        done
}

latest_version() {
    local versions
    versions="$(remote_versions || true)"
    if [[ -z "$versions" ]]; then
        printf '0.0.0\n'
        return
    fi
    printf '%s\n' "$versions" \
        | awk -F. '{ printf "%09d.%09d.%09d %s\n", $1, $2, $3, $0 }' \
        | sort -r \
        | awk 'NR == 1 { print $2 }'
}

next_version() {
    local latest="$1"
    local major minor patch
    IFS=. read -r major minor patch <<<"$latest"
    case "$BUMP" in
        patch)
            patch=$((patch + 1))
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        *)
            echo "Unsupported bump: $BUMP" >&2
            exit 1
            ;;
    esac
    printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

case "$COMMAND" in
    current)
        VERSION_VALUE="$(cat "$ROOT_DIR/VERSION")"
        is_stable_semver "$VERSION_VALUE" || { echo "Invalid VERSION file" >&2; exit 1; }
        printf '%s\n' "$VERSION_VALUE"
        ;;
    latest)
        if [[ "${#POSITIONAL[@]}" -ne 0 ]]; then
            usage >&2
            exit 1
        fi
        latest_version
        ;;
    next)
        if [[ "${#POSITIONAL[@]}" -ne 0 ]]; then
            usage >&2
            exit 1
        fi
        next_version "$(latest_version)"
        ;;
    check)
        if [[ "${#POSITIONAL[@]}" -ne 1 ]]; then
            usage >&2
            exit 1
        fi
        VERSION_TO_CHECK="$(normalize_version "${POSITIONAL[0]}")"
        if ! is_stable_semver "$VERSION_TO_CHECK"; then
            echo "Version must be stable SemVer X.Y.Z for release builds: ${POSITIONAL[0]}" >&2
            exit 1
        fi
        LATEST_VERSION="$(latest_version)"
        if [[ "$(compare_versions "$VERSION_TO_CHECK" "$LATEST_VERSION")" -le 0 ]]; then
            echo "Version $VERSION_TO_CHECK is not greater than latest remote release tag $LATEST_VERSION." >&2
            echo "Use $(next_version "$LATEST_VERSION") or a higher SemVer version." >&2
            exit 1
        fi
        printf 'version: %s\n' "$VERSION_TO_CHECK"
        printf 'latest_remote: %s\n' "$LATEST_VERSION"
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
esac
