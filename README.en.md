# QuotaBar

[Simplified Chinese](./README.md) | English

QuotaBar is a macOS menu bar app for checking Codex, Cursor, and Claude Code account quotas in one place, then quickly switching the local account used by each tool.

<img width="456" height="578" alt="QuotaBar screenshot" src="https://github.com/user-attachments/assets/bc6afa8b-e196-4be5-9982-061f453814f3" />

## Highlights

- Menu bar status: view the active account quota directly from the macOS menu bar.
- Multi-tool support: Codex, Cursor, and Claude Code.
- Quota details: remaining quota, usage status, reset window, and last updated time.
- Multi-account management: add, view, delete, and switch local accounts.
- Smart recommendation: sort accounts by consume-first or availability-first strategy to decide which account should be used next.
- Available account filter: quickly find accounts that still have usable quota.
- Status warnings: low quota, exhausted quota, refresh failures, and stale data are clearly shown.
- Manual refresh: refresh quota state whenever you need the latest data.
- Launch at login: optionally start QuotaBar when you sign in to macOS.
- Multilingual UI: Simplified Chinese, Traditional Chinese, and English.
- Update check: check for new versions from inside the app.

## Installation

Download the latest version from [GitHub Releases](https://github.com/chilohwei/QuotaBar/releases).

Choose the build that matches your Mac:

- Apple Silicon Mac: choose `arm64`
- Intel Mac: choose `x86_64`
- Not sure: choose `universal`

Install from the DMG:

1. Download and open the DMG file.
2. Drag `QuotaBar.app` into `Applications`.
3. Launch QuotaBar from the Applications folder.
4. If macOS blocks the first launch, right-click `QuotaBar.app` in Finder and choose `Open`.

You can also install with Homebrew:

```bash
brew tap chilohwei/quotabar
brew install --cask quotabar
```

Upgrade with Homebrew:

```bash
brew update
brew upgrade --cask quotabar
```

System requirement: macOS Ventura 13 or later.

## Usage

1. Launch QuotaBar.
2. Click the QuotaBar icon in the menu bar.
3. Select Codex, Cursor, or Claude Code at the top of the panel.
4. Click `Add` to import or record an account.
5. Check each account card for quota, status, and last updated time.
6. Use the available account filter when you only want accounts that can still be used.
7. Choose consume-first or availability-first sorting to find the recommended account.
8. Click `Switch` on an account, then restart the corresponding tool when prompted.

## Release

Release versions are based on the latest remote `vX.Y.Z` tag. Formal builds validate that the new version is greater than the latest stable remote release to avoid duplicate or rollback releases.

Check the latest remote version and the next patch version:

```bash
scripts/release_version.sh latest
scripts/release_version.sh next
```

Build a formal universal package:

```bash
scripts/build_macos_app.sh --arch universal
```

Build a local test package with a non-release version:

```bash
scripts/build_macos_app.sh --arch arm64 --version 1.0.2-test
```

When a new GitHub Release is created, GitHub Actions can sync the standalone Homebrew tap repository `chilohwei/homebrew-quotabar` from the generated release asset SHA256. The repository needs a `HOMEBREW_TAP_GITHUB_TOKEN` secret with write access to the tap repository.

## Privacy

QuotaBar stores only the necessary account information and usage state on your Mac.

QuotaBar does not provide its own cloud account service and does not upload your account data to any QuotaBar-owned server. You are still responsible for following the terms of Codex, Cursor, Claude Code, and any related third-party services.

## Donation

If this project helps you, please visit [https://donate.chiloh.com](https://donate.chiloh.com) to donate.

## License

Copyright (c) 2026 Chiloh. All rights reserved.

QuotaBar is free to use, copy, download, and modify for personal, educational, research, and other non-commercial purposes, as long as the copyright, attribution, and license notice are preserved.

Commercial use requires prior written permission from the author and must clearly credit QuotaBar and Chiloh. Commercial use includes, but is not limited to, selling, redistributing, integrating into paid products or services, using for business operations, providing hosted services, consulting services, integration services, or support services.

Read the full terms in [LICENSE](./LICENSE). By using QuotaBar, you acknowledge and accept the license terms.
