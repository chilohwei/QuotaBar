# 签名、公证与发布

> 发布流水线已实现：未配置签名凭据时严格回退到即席（ad-hoc）构建。启用 Developer ID 签名 + 公证只需你提供 Apple 凭据（见「阶段 A」），建议在一次受控的测试发布中开启。

## 背景与现状

- 当前正式产物为**即席（ad-hoc）签名、未公证**：`codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`，`spctl -a` 拒绝。
- 现有更新安全模型（见 [SECURITY.md](../SECURITY.md)）是**来源 + 完整性**：官方 GitHub Release host/path 白名单 + 强制 SHA256 校验 + 安装脚本校验 bundleID/版本/`codesign --verify`。
- 残留缺口（H3）：`codesign --verify --strict` 对 ad-hoc 也通过，**未锚定发布者身份**；闭合它需要发布产物拥有稳定的 Developer ID 身份。
- 本机已具备 `Developer ID Application: Xurzheng Wei (PJ5GZS2USL)` 证书（`security find-identity -v -p codesigning` 可见）。

启用 Developer ID + 公证后可一次性获得：闭合 H3、消除 Gatekeeper 摩擦（用户不再需要 `xattr` 去隔离）、并让「收紧密钥串 ACL」不再引入授权弹窗。

## 阶段 A —— 一次性 Apple 设置

两条发布路径都依赖同一组凭据，只需办一次。

1. **Developer ID Application 证书**
   - 本机确认：`security find-identity -v -p codesigning | grep "Developer ID Application"`。
   - 若缺失：用 Xcode（Settings → Accounts → Manage Certificates → `+` → Developer ID Application）或开发者门户创建（需付费 Apple Developer 账号 + Account Holder 角色）。
   - 仅 **CI 发布** 需要把它从「钥匙串访问」导出为含私钥的 `DeveloperIDApplication.p12`（设一个强导出密码）。本地发布直接用钥匙串里的身份，无需导出。

2. **App Store Connect API Key（公证用）**
   - App Store Connect → Users and Access → Integrations → **Team Keys** → `+`，角色选 `Developer`，下载 `AuthKey_XXXXXXXXXX.p8`（**只能下载一次**），记下 Key ID 与 Issuer ID。

3. **（本地发布）把公证凭据存进钥匙串 profile**，之后不用再碰 `.p8`：
   ```bash
   xcrun notarytool store-credentials QuotaBarNotary \
     --key ~/keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

## 发布路径（二选一）

### 路径 1 —— 本地发布（当前默认，推荐）

证书和公证密钥全程只在你 Mac 上，不进 GitHub Secrets、不进仓库。

```bash
export NOTARY_KEYCHAIN_PROFILE=QuotaBarNotary
scripts/release_local.sh --version 1.3.2 --dry-run   # 先看预检
scripts/release_local.sh --version 1.3.2             # 构建+签名+公证+装订 → 上传 Release → 更新 cask
```

`release_local.sh` 会自动取钥匙串里的 Developer ID 身份、校验版本领先远程 tag / 工作区干净且已推送，再调用 `build_macos_app.sh`（`NOTARIZE=true`）产出公证 DMG，用 `gh` 建 Release 上传，最后更新 Homebrew cask 与 tap。完整参数见脚本头注释或 `scripts/release_local.sh --help`。此模式下 CI 的 `gate` 任务会**不发布**（只做构建/测试），不会覆盖你的公证包。

### 路径 2 —— CI 发布（配置 Secrets 后自动启用）

在仓库 `Settings → Secrets and variables → Actions → Secrets` 添加 6 个：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperIDApplication.p12` 的输出 |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Xurzheng Wei (PJ5GZS2USL)` |
| `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `AC_API_KEY_P8_BASE64` | App Store Connect API Key 三件套（`.p8` 用 base64 编码） |

配好后 `git tag vX.Y.Z && git push` 即触发发布：工作流的 `Import signing certificate` 步骤、`build_macos_app.sh` 的 `notarize_and_staple`、以及 `gate` 判定**均已实现**（见 [`build-macos-packages.yml`](../.github/workflows/build-macos-packages.yml) 与 [`build_macos_app.sh`](../scripts/build_macos_app.sh)），无需再改代码。只有配置了 `MACOS_SIGNING_IDENTITY` 时 `gate` 才发布，因此它与本地发布不会互相覆盖。

> 顺序要点（已在构建脚本中落实）：`.sha256` 必须在 `stapler staple` **之后**计算——装订会改写 DMG 字节，校验和须描述最终文件。

## 待启用的 App 代码改动（首个 Developer ID 正式版落地后再合并）

这两项目前**尚未实现**，需在有稳定 Developer ID 签名后再启用，我会在你验证通过后单独提交。

### 自动更新锚定发布者 Team ID（`Sources/QuotaBarApp/Services/UpdateService.swift`）

在安装脚本 `writeInstallerScript` 的 `codesign --verify --deep --strict "$TMP_DEST"` **之后**、`mv "$DEST" "$BACKUP_DEST"` **之前**插入，**对 ad-hoc 无副作用**：

```bash
read_team_id() { codesign -dvv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}'; }
NEW_TEAM_ID="$(read_team_id "$TMP_DEST")"
if [[ -e "$DEST" ]]; then
    CURRENT_TEAM_ID="$(read_team_id "$DEST")"
    if [[ -n "$CURRENT_TEAM_ID" && "$CURRENT_TEAM_ID" != "not set" \
          && "$NEW_TEAM_ID" != "$CURRENT_TEAM_ID" ]]; then
        echo "Team identifier mismatch: expected $CURRENT_TEAM_ID, got ${NEW_TEAM_ID:-none}"
        exit 1
    fi
fi
```

> 当前已安装应用为 ad-hoc（无 Team ID）时判断被跳过，行为不变；发出首个 Developer ID 版本后，后续更新即被锚定到 `PJ5GZS2USL`。该逻辑由「发起更新的那个版本」自带的脚本执行，故从含此逻辑的版本起才对后续更新生效。

### 收紧密钥串 ACL（`Sources/QuotaBarApp/Services/SecretStoreService.swift`）

有稳定的 Developer ID 签名后，`applyAccessPolicy` / `openACLToAllApplications` 的「任何应用可读」放开就不再需要（它当初是为解决 ad-hoc 每次构建签名不同导致的授权弹窗）。届时可将 QuotaBar 自有条目的 ACL 收紧为「仅信任 QuotaBar 自身」，消除同机任意进程零提示读取 token 的横向面（H2）。

> **必须在 Developer ID 正式版落地后再收紧**：仍是 ad-hoc 时单独收紧会让每次更新后首次读取重新弹授权窗。

## 文档回填

启用并验证通过后，把 [README.md](../README.md) / [README.en.md](../README.en.md) 安装章节第 4 步与 [SECURITY.md](../SECURITY.md) 改回「已 Developer ID 签名并公证」，并删除 `xattr` 去隔离说明。

## 受控测试与回滚

1. 先出一个测试版（`scripts/release_local.sh --version 1.3.2-rc.1 --draft`，或给 CI 配好 Secrets 后打 `v1.3.2-rc.1` tag）。
2. 核验产物：`spctl -a -vv QuotaBar.app` 应为 `accepted (source=Notarized Developer ID)`，`xcrun stapler validate` 通过。
3. 从**上一个正式版**用应用内更新升级到该测试版，验证下载→校验→安装→重启全链路（尤其 Team ID 锚定不误伤）。
4. 回滚：本地发布不改仓库配置，停用即可；CI 发布移除签名 Secrets（或相关步骤）即恢复 ad-hoc；待启用的两项代码改动可各自独立 `git revert`。
