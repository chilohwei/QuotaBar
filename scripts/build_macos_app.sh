#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/releases"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_FILE_NAME="AppIcon.icns"
APP_NAME="QuotaBar"
BUNDLE_ID="com.chiloh.QuotaBar"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCH="arm64"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
VERSION_BUMP="patch"
SKIP_REMOTE_VERSION_CHECK="${QUOTABAR_SKIP_REMOTE_VERSION_CHECK:-false}"

usage() {
    cat <<USAGE
Usage: scripts/build_macos_app.sh [--arch arm64|x86_64|universal|all] [--version 1.0.2] [--bump patch|minor|major] [--skip-version-check]

When --version is omitted, the script reads GitHub remote tags and uses the
next patch version after the latest stable vX.Y.Z tag.

Outputs:
  dist/QuotaBar-<arch>.app
  dist/releases/QuotaBar-<version>-<arch>.dmg

Examples:
  scripts/build_macos_app.sh --arch arm64
  scripts/build_macos_app.sh --arch universal
  scripts/build_macos_app.sh --arch all
  scripts/build_macos_app.sh --arch all --version 1.0.2
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            ARCH="${2:-}"
            shift 2
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --bump)
            VERSION_BUMP="${2:-}"
            shift 2
            ;;
        --skip-version-check)
            SKIP_REMOTE_VERSION_CHECK=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$ARCH" in
    arm64|x86_64|universal|all) ;;
    *)
        echo "Unsupported arch: $ARCH" >&2
        usage >&2
        exit 1
        ;;
esac

if [[ -z "$VERSION" ]]; then
    VERSION="$("$ROOT_DIR/scripts/release_version.sh" next --bump "$VERSION_BUMP")"
    echo "Resolved release version from GitHub remote tags: $VERSION"
fi

if [[ "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    if [[ "$SKIP_REMOTE_VERSION_CHECK" == true ]]; then
        echo "Skipping remote version increment check."
    else
        "$ROOT_DIR/scripts/release_version.sh" check "$VERSION" >/dev/null
    fi
else
    echo "Skipping remote version increment check for non-release version: $VERSION"
fi

mkdir -p "$DIST_DIR" "$RELEASE_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

render_iconset() {
    local base_icon="$ICONSET_DIR/icon_512x512@2x.png"

    BASE_ICON="$base_icon" swift - <<'SWIFT'
import AppKit
import Foundation

let outputPath = ProcessInfo.processInfo.environment["BASE_ICON"]!
let size: CGFloat = 1024

func gearPath(center: NSPoint, radius: CGFloat, toothDepth: CGFloat, toothCount: Int) -> NSBezierPath {
    let path = NSBezierPath()
    let segments = max(toothCount * 18, 120)
    for index in 0 ..< segments {
        let progress = Double(index) / Double(segments)
        let angle = (-90.0 + progress * 360.0) * .pi / 180.0
        let wave = (1 + cos(Double(toothCount) * angle)) / 2
        let resolvedRadius = radius * (1 - toothDepth + toothDepth * CGFloat(wave))
        let point = NSPoint(x: center.x + CGFloat(cos(angle)) * resolvedRadius, y: center.y + CGFloat(sin(angle)) * resolvedRadius)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func drawPromptGlyph(in base: CGRect, color: NSColor) {
    let size = min(base.width, base.height)
    let lineWidth = max(size * 0.080, 1.3)
    color.setStroke()

    let chevron = NSBezierPath()
    chevron.lineWidth = lineWidth
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: base.minX + size * 0.31, y: base.midY + size * 0.14))
    chevron.line(to: NSPoint(x: base.minX + size * 0.50, y: base.midY - size * 0.02))
    chevron.line(to: NSPoint(x: base.minX + size * 0.31, y: base.midY - size * 0.18))
    chevron.stroke()

    let promptBar = NSBezierPath()
    promptBar.lineWidth = lineWidth
    promptBar.lineCapStyle = .round
    promptBar.move(to: NSPoint(x: base.minX + size * 0.58, y: base.midY - size * 0.16))
    promptBar.line(to: NSPoint(x: base.minX + size * 0.76, y: base.midY - size * 0.16))
    promptBar.stroke()
}

func drawBrandMark(in rect: CGRect) {
    let size = min(rect.width, rect.height)
    let base = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
    let center = NSPoint(x: base.midX, y: base.midY)
    let gear = gearPath(center: center, radius: size * 0.445, toothDepth: 0.14, toothCount: 10)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.21, green: 0.77, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.56, green: 0.38, blue: 0.96, alpha: 1)
    ])
    gradient?.draw(in: gear, angle: 315)
    drawPromptGlyph(in: base, color: .white)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let bounds = CGRect(origin: rect.origin, size: rect.size)
    let iconRect = bounds.insetBy(dx: size * 0.105, dy: size * 0.105)
    let radius = iconRect.width * 0.225
    let shape = NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    shape.fill()
    NSColor(calibratedWhite: 0, alpha: 0.08).setStroke()
    shape.lineWidth = max(size * 0.006, 1)
    shape.stroke()
    drawBrandMark(in: iconRect.insetBy(dx: size * 0.075, dy: size * 0.075))
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render app icon\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
SWIFT

    sips -z 16 16 "$base_icon" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -z 32 32 "$base_icon" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$base_icon" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -z 64 64 "$base_icon" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$base_icon" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -z 256 256 "$base_icon" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$base_icon" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -z 512 512 "$base_icon" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$base_icon" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
}

write_icns() {
    local output="$1"
    /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$output"
}

render_dmg_background() {
    local output="$1"

    BACKGROUND_FILE="$output" APP_NAME="$APP_NAME" swift - <<'SWIFT'
import AppKit
import Foundation

let outputPath = ProcessInfo.processInfo.environment["BACKGROUND_FILE"]!
let appName = ProcessInfo.processInfo.environment["APP_NAME"] ?? "QuotaBar"
let canvasSize = NSSize(width: 660, height: 420)
let image = NSImage(size: canvasSize)

func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    NSString(string: text).draw(in: rect, withAttributes: attrs)
}

image.lockFocus()

let bounds = CGRect(origin: .zero, size: canvasSize)
NSColor(calibratedRed: 0.944, green: 0.938, blue: 0.976, alpha: 1).setFill()
bounds.fill()

drawText(
    "安装 \(appName)",
    in: CGRect(x: 80, y: 344, width: 500, height: 34),
    size: 30,
    weight: .semibold,
    color: NSColor(calibratedWhite: 0.20, alpha: 1),
    alignment: .center
)

drawText(
    "将左侧 \(appName).app 拖动到右侧 Applications 文件夹",
    in: CGRect(x: 70, y: 312, width: 520, height: 24),
    size: 17,
    weight: .medium,
    color: NSColor(calibratedWhite: 0.42, alpha: 1),
    alignment: .center
)

let curve = NSBezierPath()
curve.move(to: NSPoint(x: 260, y: 214))
curve.curve(
    to: NSPoint(x: 404, y: 214),
    controlPoint1: NSPoint(x: 308, y: 247),
    controlPoint2: NSPoint(x: 358, y: 247)
)

if let softCurve = curve.copy() as? NSBezierPath {
    softCurve.lineWidth = 20
    softCurve.lineCapStyle = .round
    softCurve.lineJoinStyle = .round
    NSColor(calibratedRed: 0.57, green: 0.86, blue: 0.79, alpha: 0.20).setStroke()
    softCurve.stroke()
}

if let tailCurve = curve.copy() as? NSBezierPath {
    tailCurve.lineWidth = 12
    tailCurve.lineCapStyle = .round
    tailCurve.lineJoinStyle = .round
    NSColor(calibratedRed: 0.57, green: 0.86, blue: 0.79, alpha: 0.58).setStroke()
    tailCurve.stroke()
}

curve.lineWidth = 8
curve.lineCapStyle = .round
curve.lineJoinStyle = .round
NSColor(calibratedRed: 0.52, green: 0.83, blue: 0.75, alpha: 1).setStroke()
curve.stroke()

let arrowHead = NSBezierPath()
arrowHead.lineWidth = 8
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.move(to: NSPoint(x: 404, y: 214))
arrowHead.line(to: NSPoint(x: 378, y: 236))
arrowHead.move(to: NSPoint(x: 404, y: 214))
arrowHead.line(to: NSPoint(x: 378, y: 192))
NSColor(calibratedRed: 0.52, green: 0.83, blue: 0.75, alpha: 1).setStroke()
arrowHead.stroke()

drawText(
    "拖放完成后即可安装",
    in: CGRect(x: 204, y: 126, width: 252, height: 24),
    size: 14,
    weight: .semibold,
    color: NSColor(calibratedWhite: 0.46, alpha: 1),
    alignment: .center
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
SWIFT
}

apply_dmg_layout() {
    local mount_dir="$1"
    local volume_name="$2"

    /usr/bin/osascript <<APPLESCRIPT >/dev/null &
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {140, 120, 800, 560}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {165, 220}
        set position of item "Applications" of container window to {495, 220}
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    local script_pid=$!
    local waited=0
    while kill -0 "$script_pid" 2>/dev/null; do
        if [[ "$waited" -ge 12 ]]; then
            kill "$script_pid" 2>/dev/null || true
            wait "$script_pid" 2>/dev/null || true
            echo "Warning: Finder DMG layout timed out; continuing with default icon layout." >&2
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    wait "$script_pid" || {
        echo "Warning: Finder DMG layout failed; continuing with default icon layout." >&2
        return 0
    }

    # Ensure Finder writes .DS_Store before detaching the image.
    sleep 1
    sync
}

build_binary() {
    local arch="$1"
    local extra_flags=()
    if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
        # shellcheck disable=SC2206
        extra_flags=($SWIFT_BUILD_FLAGS)
    fi
    swift build ${extra_flags[@]+"${extra_flags[@]}"} -c release --arch "$arch"
}

binary_path_for_arch() {
    local arch="$1"
    local path="$ROOT_DIR/.build/${arch}-apple-macosx/release/$APP_NAME"
    if [[ -x "$path" ]]; then
        echo "$path"
        return
    fi
    path="$ROOT_DIR/.build/release/$APP_NAME"
    if [[ -x "$path" ]]; then
        echo "$path"
        return
    fi
    echo "Missing build output for $arch" >&2
    exit 1
}

resource_bundle_path_for_arch() {
    local arch="$1"
    local path="$ROOT_DIR/.build/${arch}-apple-macosx/release/QuotaBar_QuotaBarApp.bundle"
    if [[ -d "$path" ]]; then
        echo "$path"
        return
    fi
    path="$ROOT_DIR/.build/release/QuotaBar_QuotaBarApp.bundle"
    if [[ -d "$path" ]]; then
        echo "$path"
        return
    fi
    echo "Missing resource bundle for $arch" >&2
    exit 1
}

write_plist() {
    local app_dir="$1"
    cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
}

create_app() {
    local binary="$1"
    local flavor="$2"
    local resource_bundle="$3"
    local app_dir="$DIST_DIR/$APP_NAME-$flavor.app"

    rm -rf "$app_dir"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
    cp "$binary" "$app_dir/Contents/MacOS/$APP_NAME"
    chmod +x "$app_dir/Contents/MacOS/$APP_NAME"
    ditto "$resource_bundle" "$app_dir/Contents/Resources/QuotaBar_QuotaBarApp.bundle"
    write_icns "$app_dir/Contents/Resources/$ICON_FILE_NAME"
    write_plist "$app_dir"

    local codesign_args=(--force --deep --sign "$SIGNING_IDENTITY")
    if [[ "$SIGNING_IDENTITY" != "-" ]]; then
        codesign_args+=(--options runtime --timestamp)
    fi
    codesign "${codesign_args[@]}" "$app_dir" >/dev/null
    codesign --verify --deep --strict --verbose=2 "$app_dir" >/dev/null

    rm -rf "$DIST_DIR/$APP_NAME.app"
    ln -s "$(basename "$app_dir")" "$DIST_DIR/$APP_NAME.app"

    echo "$app_dir"
}

create_dmg() {
    local app_dir="$1"
    local flavor="$2"
    local staging_dir="$DIST_DIR/dmg-$flavor"
    local temp_dmg="$DIST_DIR/$APP_NAME-$VERSION-$flavor-rw.dmg"
    local dmg_path="$RELEASE_DIR/$APP_NAME-$VERSION-$flavor.dmg"
    local volume_name="$APP_NAME $VERSION"
    local mount_dir=""

    rm -rf "$staging_dir"
    rm -f "$temp_dmg"
    rm -f "$dmg_path"
    mkdir -p "$staging_dir/.background"

    ditto "$app_dir" "$staging_dir/$APP_NAME.app"
    ln -s /Applications "$staging_dir/Applications"
    render_dmg_background "$staging_dir/.background/background.png"

    hdiutil create \
        -volname "$volume_name" \
        -srcfolder "$staging_dir" \
        -ov \
        -fs HFS+ \
        -format UDRW \
        "$temp_dmg" >/dev/null

    hdiutil detach "/Volumes/$volume_name" -force >/dev/null 2>&1 || true
    local attach_output
    attach_output="$(hdiutil attach "$temp_dmg" -readwrite -nobrowse)"
    mount_dir="$(printf '%s\n' "$attach_output" | sed -n 's#^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*##p' | tail -1)"
    if [[ -z "$mount_dir" || ! -d "$mount_dir" ]]; then
        echo "Unable to mount DMG for layout" >&2
        printf '%s\n' "$attach_output" >&2
        exit 1
    fi

    apply_dmg_layout "$mount_dir" "$volume_name"

    sync

    local detached=0
    for attempt in 1 2 3 4 5; do
        if hdiutil detach "$mount_dir" >/dev/null 2>&1; then
            detached=1
            break
        fi
        sleep 1
    done
    if [[ "$detached" -eq 0 ]]; then
        hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
        sleep 1
    fi

    local converted=0
    for attempt in 1 2 3; do
        if hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null 2>&1; then
            converted=1
            break
        fi
        sleep 1
    done
    if [[ "$converted" -eq 0 || ! -f "$dmg_path" ]]; then
        echo "Failed to create DMG: $dmg_path" >&2
        exit 1
    fi

    rm -rf "$staging_dir"
    rm -f "$temp_dmg"
    shasum -a 256 "$dmg_path" | awk '{print $1}' > "$dmg_path.sha256"
    echo "$dmg_path"
}

build_flavor() {
    local flavor="$1"
    local binary=""
    local resource_bundle=""

    case "$flavor" in
        arm64|x86_64)
            build_binary "$flavor"
            binary="$(binary_path_for_arch "$flavor")"
            resource_bundle="$(resource_bundle_path_for_arch "$flavor")"
            ;;
        universal)
            build_binary arm64
            build_binary x86_64
            local arm_bin x64_bin universal_bin
            arm_bin="$(binary_path_for_arch arm64)"
            x64_bin="$(binary_path_for_arch x86_64)"
            resource_bundle="$(resource_bundle_path_for_arch arm64)"
            universal_bin="$DIST_DIR/$APP_NAME-universal-bin"
            lipo -create "$arm_bin" "$x64_bin" -output "$universal_bin"
            binary="$universal_bin"
            ;;
    esac

    local app_dir dmg_path
    app_dir="$(create_app "$binary" "$flavor" "$resource_bundle")"
    dmg_path="$(create_dmg "$app_dir" "$flavor")"
    echo "Built app: $app_dir"
    echo "DMG: $dmg_path"
}

render_iconset

if [[ "$ARCH" == "all" ]]; then
    build_flavor arm64
    build_flavor x86_64
    build_flavor universal
else
    build_flavor "$ARCH"
fi
