# 更新日志 · Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增
- 发布流水线支持 Developer ID 签名 + Apple 公证：`build_macos_app.sh` 新增 `notarize_and_staple`（`NOTARIZE=true` 时 `notarytool submit --wait → stapler staple → validate`，在两处 `.sha256` 写入前调用，因装订会改写 DMG 字节），发布工作流按需导入证书、传签名/公证凭据并校验产物。**未配 `MACOS_SIGNING_IDENTITY` secret 时严格回退到现有 ad-hoc 构建**，配置后自动激活；每次发版即 `git tag && git push` 全自动签名+公证+分发。签名凭据只存 GitHub Actions Secrets 或本机钥匙串，**绝不进仓库**。
- 新增 `scripts/check_no_signing_material.sh` 并接入 CI：仓库一旦出现证书/私钥文件（`.p12/.p8/.cer/...`）或 PEM 私钥块即让构建失败，防止把签名私钥误提交进这个公开仓库；配套在 `.gitignore` 忽略证书/密钥类文件。
- 新增 PR 与推送触发的 CI 工作流（`ci.yml`）：构建、运行全部单元测试、校验脚本语法与 house-style 卫生。
- 新增 `scripts/check_style.sh`：校验 Swift 源码的缩进（禁止制表符）、行尾空白与文件末换行，并接入 CI。经评估**未采用** swift-format 全量重排——其默认换行/花括号风格与项目既有约定冲突，且会产生约 5000 行破坏 git blame 的改动。
- 新增 `CONTRIBUTING.md`、本 `CHANGELOG.md`，并在 README 增加开发章节。
- 新增 `.swift-version` 记录工具链版本。

### 重构
- `AppState`：将 8 个分散的宿主回调闭包（更新流程、开机自启、关闭面板、重启工具、重启提示）收敛为显式的 `AppHostActions` 契约，降低上帝对象的隐式耦合。行为、`@Published` 接口与 UI 绑定均不变。

### 优化
- `QuotaHTTPClient` 默认会话与 Codex 会话增加显式请求超时（20s/40s），避免慢端点长时间挂起菜单栏刷新。

### 测试与维护
- 新增 `QuotaHTTPClient` 的 `Retry-After` 解析测试（数值秒、HTTP-date、缺失/空白、过期时间钳制到当前时刻）。
- 为 8 处 `@unchecked Sendable` 类型补充线程安全说明注释，明确各自的同步机制（`NSLock` 保护 / 初始化后不可变 / `@MainActor` 跳转 / URLSession 串行回调）。

### 文档
- 更正 README 关于签名/公证的描述，使其与 `SECURITY.md` 及实际发布产物（社区分发、即席签名、来源 + SHA256 完整性校验）保持一致。
- 新增 `docs/signing-and-notarization.md`：Developer ID 签名 + 公证 + 收紧密钥串 ACL + 更新锚定发布者身份的完整启用手册（需你在 CI 配置 Apple 凭据后受控启用），并从 `SECURITY.md` 链接。

## [1.3.1] - 2026-07-31
- 修复 Claude Code token 续期写回钥匙串，消除误报与授权弹窗。

## [1.3.0] - 2026-07-30
- 修复钥匙串只读导致的「添加账号」误报未登录。
- 完善 Claude Code 多账号刷新与状态栏用量展示。

## [1.2.5] - 2026-07-26
- Claude Code 多账号支持修复，展示真实订阅档位与周限额。
- 修复覆盖安装后的钥匙串授权弹窗。

## [1.2.4] - 2026-07-25
- 修复 Cursor 用量统计并恢复环形图展示。

## [1.2.3] - 2026-07-22
- 更新签名与公证相关说明。

## [1.2.2] - 2026-07-14
- 修复 ChatGPT 内置 Codex CLI 检测。

## [1.2.1] - 2026-07-10
- 维护性发布。

## [1.2.0] - 2026-07-10
- Codex 额度与账号重启能力完善。

## [1.1.0] - 2026-07-06
- 在宽限期后续期已失效的 Claude Code token 并写回。

[Unreleased]: https://github.com/chilohwei/QuotaBar/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.3.1
[1.3.0]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.3.0
[1.2.5]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.5
[1.2.4]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.4
[1.2.3]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.3
[1.2.2]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.2
[1.2.1]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.1
[1.2.0]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.2.0
[1.1.0]: https://github.com/chilohwei/QuotaBar/releases/tag/v1.1.0
