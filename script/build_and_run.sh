#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Fewer"
HELPER_NAME="FewerShortcutHelper"
FINDER_EXTENSION_NAME="FewerFinderExtension"
FINDER_EXTENSION_ID="com.number47.fewer.finder-extension"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/Fewer.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Fewer"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$HELPER_NAME" >/dev/null 2>&1 || true
pkill -x "$FINDER_EXTENSION_NAME" >/dev/null 2>&1 || true

cd "$PROJECT_ROOT"
xcodegen generate
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme Fewer \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  SYMROOT="$DERIVED_DATA/Build/Products" \
  OBJROOT="$DERIVED_DATA/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify

SIGNING_IDENTITY="${FEWER_SIGNING_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development/ { print $2; exit }')}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Apple Development signing identity found. Set FEWER_SIGNING_IDENTITY explicitly." >&2
  exit 1
fi

SIGNING_ENTITLEMENTS_DIR="$(mktemp -d "$PROJECT_ROOT/.build/Fewer-signing-entitlements.XXXXXX")"
cleanup_signing_entitlements() {
  /bin/rm -rf "$SIGNING_ENTITLEMENTS_DIR"
}
trap cleanup_signing_entitlements EXIT

resolved_entitlements_for_bundle() {
  local bundle="$1"
  local source_entitlements="$2"
  local info_plist="$bundle/Contents/Info.plist"
  local group_identifier
  local resolved_entitlements

  if [[ ! -f "$info_plist" ]]; then
    echo "Missing built Info.plist for signing: $info_plist" >&2
    return 1
  fi
  group_identifier="$(/usr/bin/plutil -extract FewerAppGroupIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
  if [[ ! "$group_identifier" =~ ^[A-Z0-9]{10}\.group\.com\.number47\.fewer$ ]]; then
    echo "Invalid FewerAppGroupIdentifier in $info_plist: expected a resolved Team ID-prefixed App Group." >&2
    return 1
  fi

  resolved_entitlements="$(mktemp "$SIGNING_ENTITLEMENTS_DIR/entitlements.XXXXXX")"
  /bin/cp "$source_entitlements" "$resolved_entitlements"
  if ! /usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.application-groups:0 $group_identifier" \
    "$resolved_entitlements"; then
    echo "Failed to resolve App Group entitlement for $bundle." >&2
    return 1
  fi
  printf '%s\n' "$resolved_entitlements"
}

sign_macos_bundle() {
  local bundle="$1"
  local entitlements="$2"
  local resolved_entitlements
  resolved_entitlements="$(resolved_entitlements_for_bundle "$bundle" "$entitlements")"
  while IFS= read -r binary; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$binary"
  done < <(/usr/bin/find "$bundle/Contents/MacOS" -type f \( -name '*.dylib' -o -perm -111 \))
  /usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp=none \
    --options runtime \
    --entitlements "$resolved_entitlements" \
    "$bundle"
}

sign_macos_bundle \
  "$APP_BUNDLE/Contents/PlugIns/FewerFinderExtension.appex" \
  "$PROJECT_ROOT/FewerFinderExtension/FewerFinderExtension.entitlements"
sign_macos_bundle \
  "$APP_BUNDLE/Contents/Library/LoginItems/FewerShortcutHelper.app" \
  "$PROJECT_ROOT/FewerShortcutHelper/FewerShortcutHelper.entitlements"
sign_macos_bundle \
  "$APP_BUNDLE" \
  "$PROJECT_ROOT/FewerApp/Fewer.entitlements"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/bin/pluginkit -a "$APP_BUNDLE/Contents/PlugIns/FewerFinderExtension.appex"
/usr/bin/pluginkit -e use -i "$FINDER_EXTENSION_ID"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "Fewer" OR process == "FewerFinderExtension" OR process == "FewerShortcutHelper"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem BEGINSWITH "com.number47.fewer"'
    ;;
  --verify|verify)
    test -d "$APP_BUNDLE/Contents/PlugIns/FewerFinderExtension.appex"
    test -d "$APP_BUNDLE/Contents/Library/LoginItems/FewerShortcutHelper.app"
    open_app
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "Fewer did not launch within 10 seconds" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
