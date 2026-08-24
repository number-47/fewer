#!/usr/bin/env bash
set -euo pipefail

PACKAGE_MODE="local"
SHOULD_NOTARIZE=0

usage() {
  cat <<'EOF'
用法：
  ./script/package.sh --local
  ./script/package.sh --signed
  ./script/package.sh --signed --notarize

模式：
  --local      使用本机 Apple Development 证书生成稳定签名测试 DMG（默认）
  --signed     使用 Developer ID Application 证书生成正式签名 DMG
  --notarize   将正式签名的 App 与 DMG 提交 Apple 公证

正式签名所需环境变量：
  FEWER_SIGNING_IDENTITY  Developer ID Application 证书名称或 SHA-1

公证额外需要：
  FEWER_NOTARY_PROFILE    由 notarytool store-credentials 创建的钥匙串配置名
EOF
}

while (($# > 0)); do
  case "$1" in
    --local)
      PACKAGE_MODE="local"
      ;;
    --signed)
      PACKAGE_MODE="signed"
      ;;
    --notarize)
      SHOULD_NOTARIZE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$SHOULD_NOTARIZE" == "1" && "$PACKAGE_MODE" != "signed" ]]; then
  echo "--notarize 必须与 --signed 一起使用。" >&2
  exit 2
fi

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DERIVED_DATA="$PACKAGE_ROOT/.build/PackageDerivedData"
PACKAGE_PRODUCTS="$PACKAGE_DERIVED_DATA/Build/Products/Release"
PACKAGE_APP="$PACKAGE_PRODUCTS/Fewer.app"
PACKAGE_DIST="$PACKAGE_ROOT/dist"
PACKAGE_VERSION="$(awk '/^MARKETING_VERSION[[:space:]]*=/{print $3; exit}' "$PACKAGE_ROOT/Config/Base.xcconfig")"
mkdir -p "$PACKAGE_ROOT/.build"
PACKAGE_STAGING="$(mktemp -d "$PACKAGE_ROOT/.build/Fewer-package.XXXXXX")"
PACKAGE_ENTITLEMENTS_DIR="$(mktemp -d "$PACKAGE_ROOT/.build/Fewer-package-entitlements.XXXXXX")"
PACKAGE_NOTARY_ZIP="$PACKAGE_ROOT/.build/Fewer-$PACKAGE_VERSION-notary.zip"

cleanup_package_staging() {
  /bin/rm -rf "$PACKAGE_STAGING"
  /bin/rm -rf "$PACKAGE_ENTITLEMENTS_DIR"
}
trap cleanup_package_staging EXIT

if [[ "$PACKAGE_MODE" == "signed" ]]; then
  PACKAGE_IDENTITY="${FEWER_SIGNING_IDENTITY:-}"
  PACKAGE_SUFFIX=""
  if [[ -z "$PACKAGE_IDENTITY" ]]; then
    echo "正式签名缺少 FEWER_SIGNING_IDENTITY。" >&2
    exit 2
  fi
else
  PACKAGE_IDENTITY="${FEWER_SIGNING_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development/ { print $2; exit }')}"
  if [[ -z "$PACKAGE_IDENTITY" ]]; then
    echo "本机测试包需要 Apple Development 签名证书；也可通过 FEWER_SIGNING_IDENTITY 显式指定。" >&2
    exit 2
  fi
  PACKAGE_SUFFIX="-local"
fi

PACKAGE_DMG="$PACKAGE_DIST/Fewer-$PACKAGE_VERSION$PACKAGE_SUFFIX.dmg"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1" >&2
    exit 127
  fi
}

require_command xcodegen
require_command xcodebuild
require_command xcbeautify
require_command codesign
require_command hdiutil

mkdir -p "$PACKAGE_DIST"
cd "$PACKAGE_ROOT"

echo "[1/5] 生成 Xcode 工程"
xcodegen generate

echo "[2/5] 构建 Release 应用"
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme Fewer \
  -configuration Release \
  -derivedDataPath "$PACKAGE_DERIVED_DATA" \
  SYMROOT="$PACKAGE_DERIVED_DATA/Build/Products" \
  OBJROOT="$PACKAGE_DERIVED_DATA/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify

test -d "$PACKAGE_APP/Contents/PlugIns/FewerFinderExtension.appex"
test -d "$PACKAGE_APP/Contents/Library/LoginItems/FewerShortcutHelper.app"

sign_macos_bundle() {
  local bundle="$1"
  local entitlements="$2"
  local info_plist="$bundle/Contents/Info.plist"
  local group_identifier
  local resolved_entitlements
  local sign_args=(--force --sign "$PACKAGE_IDENTITY")

  if [[ "$PACKAGE_MODE" == "signed" ]]; then
    sign_args+=(--options runtime --timestamp)
  else
    sign_args+=(--options runtime --timestamp=none)
  fi

  if [[ ! -f "$info_plist" ]]; then
    echo "缺少用于签名的构建 Info.plist：$info_plist" >&2
    return 1
  fi
  group_identifier="$(/usr/bin/plutil -extract FewerAppGroupIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
  if [[ ! "$group_identifier" =~ ^[A-Z0-9]{10}\.group\.com\.number47\.fewer$ ]]; then
    echo "构建产物中的 FewerAppGroupIdentifier 无效；需要已解析的 Team ID 前缀 App Group。" >&2
    return 1
  fi
  resolved_entitlements="$(mktemp "$PACKAGE_ENTITLEMENTS_DIR/entitlements.XXXXXX")"
  /bin/cp "$entitlements" "$resolved_entitlements"
  if ! /usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.application-groups:0 $group_identifier" \
    "$resolved_entitlements"; then
    echo "无法为 $bundle 解析 App Group entitlement。" >&2
    return 1
  fi

  while IFS= read -r binary; do
    /usr/bin/codesign "${sign_args[@]}" "$binary"
  done < <(/usr/bin/find "$bundle/Contents/MacOS" -type f \( -name '*.dylib' -o -perm -111 \))

  /usr/bin/codesign "${sign_args[@]}" --entitlements "$resolved_entitlements" "$bundle"
}

echo "[3/5] 按由内到外的顺序签名"
sign_macos_bundle \
  "$PACKAGE_APP/Contents/PlugIns/FewerFinderExtension.appex" \
  "$PACKAGE_ROOT/FewerFinderExtension/FewerFinderExtension.entitlements"
sign_macos_bundle \
  "$PACKAGE_APP/Contents/Library/LoginItems/FewerShortcutHelper.app" \
  "$PACKAGE_ROOT/FewerShortcutHelper/FewerShortcutHelper.entitlements"
sign_macos_bundle \
  "$PACKAGE_APP" \
  "$PACKAGE_ROOT/FewerApp/Fewer.entitlements"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$PACKAGE_APP"

if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
  PACKAGE_NOTARY_PROFILE="${FEWER_NOTARY_PROFILE:-}"
  if [[ -z "$PACKAGE_NOTARY_PROFILE" ]]; then
    echo "公证缺少 FEWER_NOTARY_PROFILE。" >&2
    exit 2
  fi
  require_command xcrun

  echo "[4/5] 公证并装订 App"
  /bin/rm -f "$PACKAGE_NOTARY_ZIP"
  /usr/bin/ditto -c -k --keepParent "$PACKAGE_APP" "$PACKAGE_NOTARY_ZIP"
  /usr/bin/xcrun notarytool submit "$PACKAGE_NOTARY_ZIP" \
    --keychain-profile "$PACKAGE_NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$PACKAGE_APP"
  /usr/bin/xcrun stapler validate "$PACKAGE_APP"
else
  echo "[4/5] 跳过 Apple 公证"
fi

echo "[5/5] 生成 DMG 安装包"
/usr/bin/ditto "$PACKAGE_APP" "$PACKAGE_STAGING/Fewer.app"
/bin/ln -s /Applications "$PACKAGE_STAGING/Applications"
/bin/rm -f "$PACKAGE_DMG"
/usr/bin/hdiutil create \
  -volname "Fewer" \
  -srcfolder "$PACKAGE_STAGING" \
  -format UDZO \
  -ov \
  "$PACKAGE_DMG"

if [[ "$PACKAGE_MODE" == "signed" ]]; then
  /usr/bin/codesign --force --sign "$PACKAGE_IDENTITY" --timestamp "$PACKAGE_DMG"
fi

if [[ "$SHOULD_NOTARIZE" == "1" ]]; then
  /usr/bin/xcrun notarytool submit "$PACKAGE_DMG" \
    --keychain-profile "$PACKAGE_NOTARY_PROFILE" \
    --wait
  /usr/bin/xcrun stapler staple "$PACKAGE_DMG"
  /usr/bin/xcrun stapler validate "$PACKAGE_DMG"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$PACKAGE_APP"
fi

/usr/bin/hdiutil verify "$PACKAGE_DMG"

echo
echo "打包完成：$PACKAGE_DMG"
if [[ "$PACKAGE_MODE" == "local" ]]; then
  echo "这是使用 Apple Development 稳定签名的本机测试包。其他 Mac 仍会因缺少 Developer ID 签名和公证而显示安全警告。"
else
  echo "已使用证书签名。公证状态：$([[ "$SHOULD_NOTARIZE" == "1" ]] && echo "已完成" || echo "未执行")"
fi
