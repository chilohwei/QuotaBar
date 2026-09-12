#!/usr/bin/env bash
set -euo pipefail

# Fails if any code-signing / notarization private material is tracked in this repository.
# QuotaBar is a PUBLIC repo, so a committed certificate or private key would be exposed to the
# world (and would live in git history forever, even after deletion). Certificates and keys must
# live ONLY in GitHub Actions Secrets or the developer's local keychain — never in the repo.
#
# Run locally with: bash scripts/check_no_signing_material.sh

cd "$(cd "$(dirname "$0")/.." && pwd)"

status=0

# 1) Tracked files whose extension marks them as a cert / key / keychain / provisioning profile.
#    (.key is intentionally omitted — it collides with Keynote files; PEM keys are caught below.)
bad_files="$(
    git ls-files \
        | grep -iE '\.(p12|pfx|p8|cer|der|mobileprovision|provisionprofile|keychain|keychain-db)$' \
        || true
)"
if [ -n "$bad_files" ]; then
    echo "ERROR: signing/credential files are tracked in git — never commit these:" >&2
    printf '  %s\n' $bad_files >&2
    status=1
fi

# 2) Tracked text embedding a PEM private-key block (any extension). The marker is assembled from
#    a variable so this guard script does not match itself.
dashes='-----'
key_pattern="${dashes}BEGIN [A-Z0-9 ]*PRIVATE KEY${dashes}"
if git grep -lIE -e "$key_pattern" -- . >/dev/null 2>&1; then
    echo "ERROR: a PRIVATE KEY block is present in tracked files:" >&2
    git grep -lIE -e "$key_pattern" -- . | sed 's/^/  /' >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "No committed signing material. OK."
fi
exit "$status"
