# Security Policy

QuotaBar is a local macOS menu bar app. It does not provide a QuotaBar-owned cloud account service.

## Credential Storage

- Account tokens are stored in macOS Keychain under QuotaBar-owned generic password items.
- Legacy `secrets.json` entries from older builds are read only as a migration source. When a legacy secret is successfully imported into Keychain, QuotaBar removes the migrated entry on a best-effort basis.
- App-owned account metadata, quota cache, managed profiles, and sensitive backup snapshots use user-private file or directory permissions.

## Local Tool Configuration Writes

QuotaBar can write local Codex, Cursor, and Claude Code configuration files when switching accounts, writing refreshed tokens back to the tool, or installing Claude Code statusLine integration.

## Updates

QuotaBar supports in-app self-update for convenience. Because this project currently does not use a Developer ID certificate, update verification is source- and integrity-based:

- Release metadata must come from the official `chilohwei/QuotaBar` GitHub Release endpoint.
- DMG and SHA256 assets must belong to the same official release tag.
- The downloaded DMG must match the expected SHA256.
- The app inside the DMG must have the expected bundle identifier, version, executable, and a valid code-signing state.
- QuotaBar does not remove the macOS quarantine attribute automatically.

Developer ID signing and notarization should be added before treating update verification as publisher-identity verification. A step-by-step enablement runbook (CI secrets, workflow/build-script changes, updater Team ID pinning, and keychain ACL tightening) is documented in [docs/signing-and-notarization.md](docs/signing-and-notarization.md).

## Reporting Issues

Please report security issues privately to the maintainer before opening a public issue. Include the affected version, macOS version, reproduction steps, and any relevant logs with tokens redacted.
