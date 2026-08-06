# 更新日志 · Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增
- 发布流水线支持 Developer ID 签名 + Apple 公证：`build_macos_app.sh` 新增 `notarize_and_staple`（`NOTARIZE=true` 时 `notarytool submit --wait → stapler staple → validate`，在两处 `.sha256` 写入前调用，因装订会改写 DMG 字节），发布工作流按需导入证书、传签名/公证凭据并校验产物。**未配 `MACOS_SIGNING_IDENTITY` secret 时严格回退到现有 ad-hoc 构建**，配置后自动激活；每次发版即 `git tag && git push` 全自动签名+公证+分发。签名凭据只存 GitHub Actions Secrets 或本机钥匙串，**绝不进仓库**。
- 新增 `scripts/check_no_signing_material.sh` 并接入 CI：仓库一旦出现证书/私钥文件（`.p12/.p8/.cer/...`）或 PEM 私钥块即让构建失败，防止把签名私钥误提交进这个公开仓库；配套在 `.gitignore` 忽略证书/密钥类文件。
- 新增 `scripts/release_local.sh`：在本机用钥匙串里的 Developer ID 身份构建+签名+公证+装订，再用 `gh` 上传到 GitHub Release 并更新 Homebrew cask/tap——凭据全程只在本机，不进 Secrets 也不进仓库。`build_macos_app.sh` 的公证支持新增 `NOTARY_KEYCHAIN_PROFILE`（`xcrun notarytool store-credentials` 存一次即可，无需管理 `.p8`）。
- 发布工作流新增 `gate` 任务：**仅当 CI 配置了签名密钥时才发布 Release**；未配置时（本地发布模式）CI 只构建/测试、不发布，避免 ad-hoc 包覆盖本地公证包。
- 新增 PR 与推送触发的 CI 工作流（`ci.yml`）：构建、运行全部单元测试、校验脚本语法与 house-style 卫生。
- 新增 `scripts/check_style.sh`：校验 Swift 源码的缩进（禁止制表符）、行尾空白与文件末换行，并接入 CI。经评估**未采用** swift-format 全量重排——其默认换行/花括号风格与项目既有约定冲突，且会产生约 5000 行破坏 git blame 的改动。
- 新增 `CONTRIBUTING.md`、本 `CHANGELOG.md`，并在 README 增加开发章节。
- 新增 `.swift-version` 记录工具链版本。

### 重构
- `AppState`：将 8 个分散的宿主回调闭包（更新流程、开机自启、关闭面板、重启工具、重启提示）收敛为显式的 `AppHostActions` 契约，降低上帝对象的隐式耦合。行为、`@Published` 接口与 UI 绑定均不变。

### 优化
- **额度耗尽时把更优账号排到最前**：账号列表原本无条件把当前账号钉在顶部，即使它已用完，导致该切换时最合适的账号被压在下面。现改为「仅当当前账号仍可用时才钉顶」——一旦当前账号额度用尽/被限流，它按策略回落到正常排序，仍有余量的推荐账号自然升到第一位（配合既有「推荐」标记），用户自己一键切换。当前账号未用尽时的钉顶行为不变，列表不会在你正用着的账号下方乱跳。新增单元测试。
- **额度卡片固定双窗口布局**：Codex / Claude Code 的账号卡片现在把「5 小时」与「周」窗口固定为两个槽位，某个窗口缺席或为 0% 时也保留该格（显示 `--`/`0%`），不再塌成一列；Codex 的「额外用量 credits」独立成第三格、不再顶替周窗口，Claude 的模型维度周窗口（如 `7d·Opus`）也照常展示。修复根因：旧的 `orderedMetrics` 会丢弃缺失窗口，导致只剩单窗口时卡片收窄。
- 实时刷新：让菜单栏在**额度变化时即时更新**，覆盖两类确定性变化——
  - **用量下降（使用工具）**：新增用量事件驱动刷新,监听 Codex（`~/.codex/.codex-global-state.json`）与 Cursor（`state.vscdb`）的本地活动文件,一使用就触发实时拉取;空闲时零额外请求;每工具合并节流（≤10s）。Claude Code 仍由 statusLine 监听保持实时。
  - **额度回满（窗口重置）**：按每个账号最近的 `resetAt` 边界**精确定时**刷新（+10s 让服务端先翻窗）,重置一到即显示回满,不再等最长 150s 周期。
  - 周期循环（150s）仍作兜底,覆盖无本地信号的服务端变化（如他机使用）——此类无推送通道,只能轮询,无法真正「即时」。
  - 新增按工具节流与重置边界定时的单元测试。
- 自动刷新：周期性后台刷新循环改为**按新鲜度过滤**（`refreshActiveAccountsIfNeeded`，间隔取自配额自适应的刷新间隔），跳过刚被前台/面板/唤醒事件刷新过的账号，减少 Codex/Cursor 每周期的冗余网络请求；正常自适应节奏（默认 150s / 低配额 75s / 电池空闲 450s）不变。新增 `shouldRefreshAccount` 新鲜度门控的单元测试。
- `QuotaHTTPClient` 默认会话与 Codex 会话增加显式请求超时（20s/40s），避免慢端点长时间挂起菜单栏刷新。

### 测试与维护
- 清理：移除全仓引用计数确认无用的死代码——`CursorProvider.parsePlanWindow`（已被 `parseTeamDollarPlanWindow` + `parseIndividualPercentPlanWindow` 取代）与 `QuotaSnapshotCacheStore.load(accountID:)` 单参冗余重载（仅两参版本被调用）；构建与 185 项测试均不受影响。
- 文档：整合 `docs/signing-and-notarization.md`（去掉过时的阶段/步骤编号与两段「已实现」的粘贴代码，把一次性 Apple 设置合并为「阶段 A」，本地/CI 两条发布路径各归一处），并修正 `CONTRIBUTING.md` 发布流程与 `SECURITY.md` 中与当前 `gate` 行为不一致的表述。
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
