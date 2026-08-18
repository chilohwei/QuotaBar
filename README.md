

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
4. 当前版本为社区分发，采用即席（ad-hoc）签名、未经 Apple 公证，因此首次启动会被 Gatekeeper 拦截。这是预期行为，安全性由「官方 Release 来源校验 + SHA256 完整性校验」保证（详见 [SECURITY.md](./SECURITY.md)）。
5. 核对下载来源与每个 Release 附带的 SHA256 无误后，移除 quarantine 标记再启动：

```bash
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

也可以使用 Homebrew 安装：

```bash
brew tap chilohwei/quotabar
brew install --cask quotabar
```

Homebrew cask 安装的是 `universal` 版本，适用于 Apple Silicon 与 Intel Mac。

使用 Homebrew 升级：

```bash
brew update
brew upgrade --cask quotabar
```

如果 Homebrew 安装后的应用被 Gatekeeper 拦截，同样可以在确认来源后对 `/Applications/QuotaBar.app` 执行上面的 `xattr` 命令。

系统要求：macOS Ventura 13 或更高版本。

## 怎么用

1. 启动 QuotaBar。
2. 点击菜单栏中的 QuotaBar 图标，打开账号面板。
3. 在面板顶部选择 Codex、Cursor 或 Claude Code。
4. 点击“添加”导入或记录账号。
5. 查看账号卡片上的额度、状态和更新时间。
6. 需要切换账号时，点击对应账号的“切换”。
7. 按提示重启对应应用，让账号切换生效。

## 开发

QuotaBar 使用 Swift Package Manager 构建，无第三方依赖。环境要求：macOS 13+、Xcode 26.x（Swift 6.1+）。

```bash
swift build            # 构建
swift run QuotaBar     # 本地运行（图标出现在菜单栏，而非 Dock）
swift test             # 运行单元测试
```

主要目录：`Sources/QuotaBar/`（入口）、`Sources/QuotaBarApp/App`（生命周期与状态栏）、`Core`（`AppState` 状态中枢与刷新策略）、`Providers`（Codex/Cursor/Claude Code）、`Services`（Keychain/HTTP/通知/更新）、`UI`（SwiftUI 面板）、`Tests/`（单元测试）。

构建、发布与贡献规范见 [CONTRIBUTING.md](./CONTRIBUTING.md)，版本历史见 [CHANGELOG.md](./CHANGELOG.md)。

## 隐私说明

QuotaBar 本地优先：账号 token 会保存到 macOS Keychain，本地账号元数据和额度缓存会保存在 `~/Library/Application Support/QuotaBar/`。

为导入/切换账号、刷新 token、安装 Claude Code statusLine 和展示额度，QuotaBar 会读写 Codex、Cursor、Claude Code 的本机配置文件；额度刷新会请求对应官方接口，检查更新会访问 GitHub Releases。QuotaBar 不提供自有云端账号服务，也不会把你的账号数据上传到 QuotaBar 自有服务器。

## 支持与反馈

如果你遇到问题，或希望提出功能建议，可以在 [GitHub Issues](https://github.com/chilohwei/QuotaBar/issues) 反馈。

如果这个项目对你有帮助，也欢迎通过 [donate.chiloh.com](https://donate.chiloh.com) 支持作者。

## 版权与授权

Copyright (c) 2026 Chiloh. All rights reserved.

QuotaBar 允许个人、教育、研究和其他非商业用途免费使用、复制、下载和修改，但必须保留版权、署名和许可说明。

商业使用必须事先获得作者书面授权，并清晰标注 QuotaBar 和 Chiloh。商业使用包括但不限于销售、再分发、集成到付费产品或服务、用于商业运营、提供托管服务、咨询服务、集成服务或支持服务。

完整条款请阅读 [LICENSE](./LICENSE)。使用 QuotaBar 即表示你理解并接受该许可说明。
