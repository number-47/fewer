#!/usr/bin/env bash
# 只读 CI 验证脚本：核心单测 + 完整无签名 Debug 构建 + 模板校验 + 三产物检查。
# 刻意不包含 .codex/hooks 的本地 receipt/stop_gate 逻辑，仅用于无签名 CI 门禁。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/.build/DerivedData"
SYM="$DERIVED/Build/Products"
OBJ="$DERIVED/Build/Intermediates.noindex"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1" >&2
    exit 127
  fi
}
require_command xcodebuild
require_command xcbeautify
require_command xcodegen

echo "[1/4] FewerCore 单元测试"
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme FewerCore \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  SYMROOT="$SYM" \
  OBJROOT="$OBJ" \
  CODE_SIGNING_ALLOWED=NO \
  test | xcbeautify

echo "[2/4] 完整 Debug 构建（无签名）"
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme Fewer \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  SYMROOT="$SYM" \
  OBJROOT="$OBJ" \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify

echo "[3/4] 模板校验"
./script/verify_templates.sh

echo "[4/4] 三产物检查（App / Finder Extension / Shortcut Helper）"
test -d "$SYM/Debug/Fewer.app"
test -d "$SYM/Debug/Fewer.app/Contents/PlugIns/FewerFinderExtension.appex"
test -d "$SYM/Debug/Fewer.app/Contents/Library/LoginItems/FewerShortcutHelper.app"

echo "CI 验证通过"
