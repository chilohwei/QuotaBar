# 贡献指南 · Contributing

感谢你对 QuotaBar 的关注！本文件说明如何在本地开发、测试与发布。

## 环境要求

- macOS 13（Ventura）或更高版本
- Xcode 26.x（Swift 6.1+），或对应的 Swift 工具链
- 无第三方依赖：QuotaBar 完全基于系统框架与 Swift Package Manager 构建

## 本地开发

```bash
swift build            # 构建全部 target
swift run QuotaBar     # 本地运行菜单栏应用
swift test             # 运行单元测试
```

> 说明：QuotaBar 是菜单栏应用（`setActivationPolicy(.accessory)`），运行后图标出现在系统菜单栏右侧，而非 Dock。

## 项目结构

| 目录 | 职责 |
| --- | --- |
| `Sources/QuotaBar/` | 可执行入口（`main.swift`） |
| `Sources/QuotaBarApp/App/` | 应用生命周期、状态栏控制器 |
| `Sources/QuotaBarApp/Core/` | `AppState` 状态中枢、刷新/退避策略、本地化 |
| `Sources/QuotaBarApp/Providers/` | Codex / Cursor / Claude Code 三家 Provider |
| `Sources/QuotaBarApp/Services/` | Keychain、HTTP、通知、自动更新、文件监听 |
| `Sources/QuotaBarApp/Storage/` | 账号存储、额度快照缓存、路径 |
| `Sources/QuotaBarApp/UI/` | SwiftUI 面板与卡片 |
| `Tests/QuotaBarAppTests/` | 单元测试 |

## 代码约定

- 遵循仓库根目录的 `.editorconfig`（4 空格缩进、LF、文件末尾换行、去除行尾空白）。提交前可运行 `bash scripts/check_style.sh` 校验，CI 也会执行同一检查。项目**不使用** swift-format 全量重排——其默认风格与既有约定冲突，请保持与周边代码一致的手写风格。
- 保持零第三方依赖；新增能力优先使用系统框架。
- 日志统一使用 `AppLog`（`os.Logger`），并按敏感度标注 `privacy:`——账号 ID/工具名用 `.public`，错误描述用 `.private`，切勿把 token/secret 写入日志。
- 外部命令一律通过 `Process` 的参数数组调用，禁止拼接 shell 字符串。
- 提交信息沿用现有风格：简洁的中文主题句 + 必要的正文说明。仓库启用了提交与标签的 SSH 签名。

## 分支与 CI

- 从最新的 `main` 切分支开发，通过 Pull Request 合并。
- 每个 PR 与推送到 `main` 都会触发 [`ci.yml`](.github/workflows/ci.yml)：构建 + 运行全部单元测试 + 校验脚本语法。请确保 CI 通过后再合并。

## 发布流程

发布由标签驱动，无需手动上传产物：

1. 确认 `main` 为待发布状态且 CI 通过。
2. 选择新版本号（必须高于远程最新的 `vX.Y.Z` 标签；`scripts/release_version.sh next` 可给出建议）。
3. 打带注释的签名标签并推送：

   ```bash
   git tag -a v1.3.2 -m "版本说明"
   git push origin v1.3.2
   ```

4. [`build-macos-packages.yml`](.github/workflows/build-macos-packages.yml) 会自动：三架构（arm64 / x86_64 / universal）构建 DMG → 校验 SHA256 → 发布 GitHub Release → 更新 Homebrew cask 与独立 tap → 将 cask 变更提交回 `main`。

本地打包（自测用）：

```bash
QUOTABAR_SKIP_DMG_LAYOUT=true QUOTABAR_SKIP_REMOTE_VERSION_CHECK=true \
  scripts/build_macos_app.sh --arch arm64 --version 0.0.0-dev
```

## 安全

如发现安全问题，请先按 [SECURITY.md](./SECURITY.md) 私下联系维护者，并在日志中隐去 token 后再附上。
