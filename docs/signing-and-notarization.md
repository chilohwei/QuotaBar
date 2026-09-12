# 构建、签名与公证

QuotaBar 通过 GitHub Releases 分发 DMG，提供 arm64、x86_64 和 universal 架构。版本号由根目录 `VERSION` 管理。

## 本地打包

```bash
scripts/build_macos_app.sh --arch arm64
scripts/build_macos_app.sh --arch universal
```

产物位于 `dist/` 与 `dist/releases/`，每个 DMG 附带 SHA-256 校验文件。默认使用 ad-hoc 签名。可通过 `--version` 指定版本，通过 `--skip-version-check` 构建开发版本。

## Developer ID 签名

在 macOS 钥匙串中配置 Developer ID Application 证书，并设置 `SIGNING_IDENTITY`。开启 `NOTARIZE=true` 时，还需提供以下任一凭据方式：

- `NOTARY_KEYCHAIN_PROFILE`：由 `xcrun notarytool store-credentials` 创建的钥匙串配置。
- App Store Connect API：`AC_API_KEY_ID`、`AC_API_ISSUER_ID`，以及 `AC_API_KEY_PATH` 或 `AC_API_KEY_P8_BASE64`。

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_KEYCHAIN_PROFILE="quotabar-notary"
NOTARIZE=true scripts/build_macos_app.sh --arch universal
```

脚本检查应用签名，等待 Apple 接受公证请求，并装订与验证 DMG 公证票据。SHA-256 在装订完成后生成。

## GitHub Actions

推送 `vX.Y.Z` 标签触发三种架构的测试和打包。发布说明位于 `docs/releases/X.Y.Z.md`。签名和公证需要配置：

- `MACOS_SIGNING_IDENTITY`
- `MACOS_CERT_P12_BASE64`
- `MACOS_CERT_PASSWORD`
- `AC_API_KEY_ID`
- `AC_API_ISSUER_ID`
- `AC_API_KEY_P8_BASE64`

未配置签名身份时，CI 使用 ad-hoc 签名并发布 DMG。工作流使用临时钥匙串，结束后清理签名材料。

也可使用 `scripts/release_local.sh --version X.Y.Z` 在本机完成签名、公证和上传；需要已登录的 GitHub CLI。`--dry-run` 只执行预检查，`--draft` 创建草稿 Release。

## 产物验证

```bash
codesign --verify --deep --strict dist/QuotaBar-arm64.app
hdiutil verify dist/releases/QuotaBar-1.0.0-arm64.dmg
```

公证产物还应通过 `xcrun stapler validate`。验证发布附件的校验值后，再检查安装与应用内更新流程。证书、私钥、密码和 API 凭据不得提交到仓库。
