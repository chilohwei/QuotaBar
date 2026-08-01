# P4 运行手册：Developer ID 签名 + 公证 + 收紧密钥串 ACL

> 状态：**待启用**。本手册是 Review 中 P4（安全强化）的交付物。所有步骤都会触及**发布流水线**与**自动更新这条不可回滚、无法在本地端到端验证的关键路径**，且依赖只有你能提供的 Apple 签名/公证凭据，因此不做无人值守改动，改由本手册指导你在一次**受控的测试发布**中启用。

## 背景与现状

- 当前发布产物为**即席（ad-hoc）签名、未公证**：`codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`，`spctl -a` 拒绝。
- 现有更新安全模型（见 [SECURITY.md](../SECURITY.md)）是**来源 + 完整性**：官方 GitHub Release host/path 白名单 + 强制 SHA256 校验 + 安装脚本校验 bundleID/版本/`codesign --verify`。
- 残留缺口（H3）：`codesign --verify --strict` 对 ad-hoc 也通过，**未锚定发布者身份**。要闭合它，必须先让发布产物拥有稳定的 Developer ID 身份。
- 你本机已具备 `Developer ID Application: Xurzheng Wei (PJ5GZS2USL)` 证书（`security find-identity -p codesigning` 可见）。

启用 Developer ID + 公证后可**一次性**获得：闭合 H3、消除 Gatekeeper 摩擦（用户不再需要 `xattr` 去隔离）、并让「收紧密钥串 ACL」不再引入授权弹窗。

## 前置条件

1. Apple Developer 账号（付费），`Developer ID Application` 证书及其私钥（`.p12` 导出）。
2. 公证凭据，二选一（推荐 App Store Connect API Key）：
   - **API Key**：`AuthKey_XXXX.p8` + Key ID + Issuer ID。
   - 或 Apple ID + app-specific password + Team ID。

## 步骤 1 —— 配置 GitHub Secrets

在仓库 `Settings → Secrets and variables → Actions` 添加：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperIDApplication.p12` 的输出 |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Xurzheng Wei (PJ5GZS2USL)` |
| `AC_API_KEY_ID` / `AC_API_ISSUER_ID` / `AC_API_KEY_P8_BASE64` | App Store Connect API Key 三件套 |

## 步骤 2 —— 发布工作流（`.github/workflows/build-macos-packages.yml`）

在 `Build DMG` 步骤前，新增导入签名证书到临时钥匙串的步骤，并把签名身份传给构建脚本：

```yaml
      - name: Import signing certificate
        env:
          CERT_P12_BASE64: ${{ secrets.MACOS_CERT_P12_BASE64 }}
          CERT_PASSWORD: ${{ secrets.MACOS_CERT_PASSWORD }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/build.keychain-db"
          security create-keychain -p "" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "" "$KEYCHAIN"
          echo "$CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$CERT_PASSWORD" \
            -T /usr/bin/codesign
          security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
          security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null
          rm -f "$RUNNER_TEMP/cert.p12"
```

`Build DMG` 步骤传入签名身份（构建脚本已支持 `SIGNING_IDENTITY`，非 `-` 时自动附加 `--options runtime --timestamp`，见 `scripts/build_macos_app.sh` 的 `create_app`）：

```yaml
          SIGNING_IDENTITY="${{ secrets.MACOS_SIGNING_IDENTITY }}" \
          NOTARIZE=true \
          AC_API_KEY_ID="${{ secrets.AC_API_KEY_ID }}" \
          AC_API_ISSUER_ID="${{ secrets.AC_API_ISSUER_ID }}" \
          AC_API_KEY_P8_BASE64="${{ secrets.AC_API_KEY_P8_BASE64 }}" \
          bash scripts/build_macos_app.sh --arch "${{ matrix.arch }}" --version "${{ steps.meta.outputs.version }}"
```

## 步骤 3 —— 构建脚本增加公证 + 装订（`scripts/build_macos_app.sh`）

`create_dmg` 生成 `$dmg_path` 后、写 `.sha256` **之前**，新增（对已签名 DMG 公证并装订）：

```bash
notarize_and_staple() {
    local dmg_path="$1"
    [[ "${NOTARIZE:-false}" == true ]] || return 0
    local key_file="$DIST_DIR/ac_api_key.p8"
    printf '%s' "$AC_API_KEY_P8_BASE64" | base64 --decode > "$key_file"
    xcrun notarytool submit "$dmg_path" \
        --key "$key_file" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" \
        --wait
    rm -f "$key_file"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
}
```

在 `create_dmg` 里 `shasum ... > "$dmg_path.sha256"` 之前调用 `notarize_and_staple "$dmg_path"`。
> 顺序要点：SHA256 必须在**装订之后**计算，因为装订会改写 DMG 内容 —— 自动更新会校验这个 SHA256，二者必须对应同一份最终文件。

## 步骤 4 —— 自动更新：锚定发布者身份（`Sources/QuotaBarApp/Services/UpdateService.swift`）

在安装脚本 `writeInstallerScript` 里 `codesign --verify --deep --strict "$TMP_DEST"` **之后**，新增**向前兼容、对 ad-hoc 无副作用**的 Team ID 锚定：

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

> 为何安全：当前已安装应用为 ad-hoc（无 Team ID）时该判断被跳过，行为不变；一旦你发出首个 Developer ID 版本，之后的更新即被锚定到 `PJ5GZS2USL`。
> 生效时机：该逻辑由「发起更新的那个版本」自带的脚本执行，因此从「含此逻辑的版本」起才对后续更新生效。

## 步骤 5 —— 收紧密钥串 ACL（`Sources/QuotaBarApp/Services/SecretStoreService.swift`）

当发布拥有**稳定的 Developer ID 签名**后，`applyAccessPolicy` / `openACLToAllApplications` 的「任何应用可读」放开就不再需要（它当初是为解决 ad-hoc 每次构建签名不同导致的授权弹窗）。届时可将 QuotaBar 自有条目的 ACL 收紧为「仅信任 QuotaBar 自身」，消除同机任意进程零提示读取 token 的横向面（H2）。

> **必须与步骤 1–3 同批启用**：在仍是 ad-hoc 的情况下单独收紧 ACL，会立刻让每次更新后的首次读取重新弹授权窗。

## 步骤 6 —— 文档回填

启用并验证通过后，把 [README.md](../README.md) / [README.en.md](../README.en.md) 安装章节第 4 步与 [SECURITY.md](../SECURITY.md) 改回「已 Developer ID 签名并公证」，并删除 `xattr` 去隔离说明。

## 受控测试与回滚

1. 打一个测试 tag（如 `v1.3.2-rc.1`），观察 CI 是否成功签名+公证+装订。
2. 下载产物：`spctl -a -vv QuotaBar.app` 应为 `accepted (source=Notarized Developer ID)`；`xcrun stapler validate` 通过。
3. 从**上一个正式版**用应用内更新升级到该测试版，验证下载→校验→安装→重启全链路（尤其步骤 4 的 Team ID 锚定不误伤）。
4. 回滚：移除工作流的签名/公证步骤与 `NOTARIZE=true` 即恢复现有 ad-hoc 流程；步骤 4/5 的代码改动可独立 revert。
