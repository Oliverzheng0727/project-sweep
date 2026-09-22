#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
source scripts/build-support.sh
swift build "${BUILD_ARGS[@]}" -c release --arch arm64
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" -c release --arch arm64 --show-bin-path)"
APP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ProjectSweep-build.XXXXXX")"
trap 'rm -rf "$APP_STAGE"' EXIT
APP_DIR="$APP_STAGE/Project Sweep.app"
DELIVERY_APP="$PROJECT_DIR/dist/Project Sweep.app"
ASSET_DIR="$PROJECT_DIR/.build/app-assets"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$ASSET_DIR/AppIcon.iconset" "$PROJECT_DIR/dist"
cp "$BIN_DIR/ProjectSweep" "$APP_DIR/Contents/MacOS/ProjectSweep"
ditto --norsrc --noextattr "$BIN_DIR/ProjectSweep_ProjectSweepApp.bundle" "$APP_DIR/Contents/Resources/ProjectSweep_ProjectSweepApp.bundle"
ditto --norsrc --noextattr "$BIN_DIR/ProjectSweep_CleanupCore.bundle" "$APP_DIR/Contents/Resources/ProjectSweep_CleanupCore.bundle"
for LOCALE in en zh-Hans; do
    mkdir -p "$APP_DIR/Contents/Resources/$LOCALE.lproj"
    ditto --norsrc --noextattr "$PROJECT_DIR/Sources/CleanupCore/Resources/$LOCALE.lproj" "$APP_DIR/Contents/Resources/$LOCALE.lproj"
done
swift scripts/make-icon.swift "$ASSET_DIR/icon-source.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ASSET_DIR/icon-source.png" --out "$ASSET_DIR/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ASSET_DIR/icon-source.png" --out "$ASSET_DIR/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ASSET_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.projectsweep.app</string>
<key>CFBundleName</key><string>Project Sweep</string>
<key>CFBundleDisplayName</key><string>项目清理</string>
<key>CFBundleExecutable</key><string>ProjectSweep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>13</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>仅检查你选择的项目文件夹，并在确认后清理所选文件。</string>
<key>NSDesktopFolderUsageDescription</key><string>访问你选择的桌面项目文件夹。</string>
<key>NSDownloadsFolderUsageDescription</key><string>访问你选择的下载项目文件夹。</string>
<key>NSHumanReadableCopyright</key><string>Project Sweep · 2026</string>
</dict></plist>
PLIST
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
# Sign outside sync-managed folders, which can add FinderInfo between clearing
# attributes and signing. Package this clean bundle before exposing it to Finder.
ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$PROJECT_DIR/dist/ProjectSweep-macOS-arm64.zip"
# Replace the generated bundle instead of merging it: build-engine changes can move
# resources into Contents/, leaving old files behind and invalidating the signature.
if [[ -e "$DELIVERY_APP" ]]; then
    mv "$DELIVERY_APP" "$APP_STAGE/previous-build.app"
fi
ditto --norsrc --noextattr "$APP_DIR" "$DELIVERY_APP"
xattr -cr "$DELIVERY_APP"
if ! codesign --verify --strict "$DELIVERY_APP"; then
    printf '%s\n' '同步目录再次添加了文件属性；已签名 ZIP 不受影响。请将 ZIP 解压到本机 ~/Applications 后运行。' >&2
fi
printf '\nApp ready: %s\n' "$DELIVERY_APP"
