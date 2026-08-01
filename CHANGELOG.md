# 更新日志 · Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增
- 新增 PR 与推送触发的 CI 工作流（`ci.yml`）：构建、运行全部单元测试、校验脚本语法与 house-style 卫生。
- 新增 `scripts/check_style.sh`：校验 Swift 源码的缩进（禁止制表符）、行尾空白与文件末换行，并接入 CI。经评估**未采用** swift-format 全量重排——其默认换行/花括号风格与项目既有约定冲突，且会产生约 5000 行破坏 git blame 的改动。
- 新增 `CONTRIBUTING.md`、本 `CHANGELOG.md`，并在 README 增加开发章节。
- 新增 `.swift-version` 记录工具链版本。

### 重构
- `AppState`：将 8 个分散的宿主回调闭包（更新流程、开机自启、关闭面板、重启工具、重启提示）收敛为显式的 `AppHostActions` 契约，降低上帝对象的隐式耦合。行为、`@Published` 接口与 UI 绑定均不变。

### 优化
- `QuotaHTTPClient` 默认会话与 Codex 会话增加显式请求超时（20s/40s），避免慢端点长时间挂起菜单栏刷新。

### 文档
- 更正 README 关于签名/公证的描述，使其与 `SECURITY.md` 及实际发布产物（社区分发、即席签名、来源 + SHA256 完整性校验）保持一致。

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
