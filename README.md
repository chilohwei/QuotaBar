# QuotaBar

[English](./README.en.md) | 简体中文

QuotaBar 是一款 macOS 菜单栏工具，帮助你集中查看 Codex、Cursor、Claude Code 的账号额度，并在需要时快速切换本机正在使用的账号。

<img width="456" height="578" alt="image" src="https://github.com/user-attachments/assets/bc6afa8b-e196-4be5-9982-061f453814f3" />

## 核心功能

- 菜单栏常驻：从 macOS 菜单栏直接查看当前账号剩余额度。
- 多工具支持：支持 Codex、Cursor、Claude Code。
- 额度查看：展示剩余额度、用量状态、重置周期和更新时间。
- 多账号管理：支持添加、查看、删除和切换本机账号。
- 智能推荐：支持按「消耗优先」或「余量优先」排序，推荐更适合当前使用的账号。
- 可用账号筛选：快速找出仍有可用额度的账号。
- 状态提醒：额度不足、无额度、刷新失败等状态会在面板中清晰展示。
- 手动刷新：需要确认最新状态时，可以随时刷新。
- 开机自启：可选择随 macOS 登录自动启动。
- 多语言界面：支持简体中文、繁体中文和 English。
- 检查更新：可在应用内检查新版本。
- 本地写入控制：可在设置中关闭对 Codex、Cursor、Claude Code 本地配置的写入，进入只读管理模式。

## 安装

你可以从 [GitHub Releases](https://github.com/chilohwei/QuotaBar/releases) 下载最新版本。

下载时请选择适合你的版本：

- Apple Silicon Mac：选择 `arm64`
- Intel Mac：选择 `x86_64`
- 不确定芯片类型：选择 `universal`

安装步骤：

1. 下载并打开 DMG 文件。
2. 将 `QuotaBar.app` 拖入 `Applications`。
3. 从“应用程序”文件夹启动 QuotaBar。
4. QuotaBar 当前通过 Homebrew/GitHub Releases 分发，未使用 Developer ID 签名。如果 macOS 首次启动时拦截，请在 Finder 中右键点击 `QuotaBar.app`，选择“打开”。
5. 如果你已经确认下载来源和 SHA256，但 macOS 仍阻止启动，可以手动移除 quarantine 标记：

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

也可以使用 Homebrew 安装：

```bash
brew tap chilohwei/quotabar
brew install --cask quotabar
```

使用 Homebrew 升级：

```bash
brew update
brew upgrade --cask quotabar
```

如果 Homebrew 安装后的应用被 Gatekeeper 拦截，同样可以在确认来源后对 `/Applications/QuotaBar.app` 执行上面的 `xattr` 命令。

发布新版本时，GitHub Actions 会在 Release 创建后根据远端 DMG 的实际 SHA256
自动同步独立 tap 仓库 `chilohwei/homebrew-quotabar`。仓库需要配置
`HOMEBREW_TAP_GITHUB_TOKEN` secret，且该 token 需要对 tap 仓库有写权限。

系统要求：macOS Ventura 13 或更高版本。

## 怎么用

1. 启动 QuotaBar。
2. 点击菜单栏中的 QuotaBar 图标，打开账号面板。
3. 在面板顶部选择 Codex、Cursor 或 Claude Code。
4. 点击“添加”导入或记录账号。
5. 查看账号卡片上的额度、状态和更新时间。
6. 需要切换账号时，点击对应账号的“切换”。
7. 按提示重启对应应用，让账号切换生效。

## 发版

版本号以 GitHub 远程 `vX.Y.Z` tag 为准。正式打包会校验新版本必须大于远程最新稳定版本，避免重复发布或回退版本号。

查看远程最新版本和下一个 patch 版本：

```bash
scripts/release_version.sh latest
scripts/release_version.sh next
```

本地正式打包时不传 `--version` 会自动使用远程最新版本的下一个 patch：

```bash
scripts/build_macos_app.sh --arch universal
```

当前项目没有 Developer ID 证书，构建脚本默认使用 ad-hoc 签名。应用内更新仅接受 `chilohwei/QuotaBar` 官方 GitHub Release 的 DMG 与 SHA256 asset，会校验下载包 SHA256、包内 Bundle ID、版本号、可执行文件和代码签名状态，但不会自动移除 macOS quarantine 标记。

测试包请使用非正式版本号，避免和正式 release 混淆：

```bash
scripts/build_macos_app.sh --arch arm64 --version 1.0.2-test
```

## 隐私说明

QuotaBar 只在本机保存必要的账号信息和使用状态。账号 token 会保存到 macOS Keychain；旧版本留下的 `secrets.json` 会在读取时迁移到 Keychain，并尽量移除已迁移条目。

QuotaBar 会读取和修改 Codex、Cursor、Claude Code 在本机的登录/配置文件，以便导入账号、切换账号和展示额度。本地账号元数据、额度缓存和托管配置会保存在 `~/Library/Application Support/QuotaBar/`。

如果你希望 QuotaBar 只查看额度而不修改第三方工具配置，可以在设置中关闭“允许修改工具配置”。关闭后，账号切换、主动写回刷新后的 token、Claude Code statusLine 安装等写操作会被阻止；导入本机账号和额度刷新仍可继续使用。

QuotaBar 不提供自有云端账号服务，也不会把你的账号数据上传到 QuotaBar 自有服务器。检查更新会访问 GitHub Releases；额度刷新会请求 Codex、Cursor、Claude Code 对应的官方接口。你仍需自行遵守 Codex、Cursor、Claude Code 及相关第三方服务的使用条款。

## 支持与反馈

如果你遇到问题，或希望提出功能建议，可以在 [GitHub Issues](https://github.com/chilohwei/QuotaBar/issues) 反馈。

如果这个项目对你有帮助，也欢迎通过 [donate.chiloh.com](https://donate.chiloh.com) 支持作者。

## 版权与授权

Copyright (c) 2026 Chiloh. All rights reserved.

QuotaBar 允许个人、教育、研究和其他非商业用途免费使用、复制、下载和修改，但必须保留版权、署名和许可说明。

商业使用必须事先获得作者书面授权，并清晰标注 QuotaBar 和 Chiloh。商业使用包括但不限于销售、再分发、集成到付费产品或服务、用于商业运营、提供托管服务、咨询服务、集成服务或支持服务。

完整条款请阅读 [LICENSE](./LICENSE)。使用 QuotaBar 即表示你理解并接受该许可说明。
