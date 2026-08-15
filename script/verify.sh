#!/usr/bin/env bash
set -euo pipefail

VERIFY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DERIVED_DATA="$VERIFY_ROOT/.build/DerivedData"
VERIFY_STOP_GATE="$VERIFY_ROOT/.codex/hooks/stop_gate.py"
VERIFY_HOOK_TESTS="$VERIFY_ROOT/.codex/hooks/test_stop_gate.py"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1" >&2
    exit 127
  fi
}

require_command xcodebuild
require_command xcbeautify

cd "$VERIFY_ROOT"

VERIFY_FINGERPRINT_BEFORE="$(/usr/bin/python3 "$VERIFY_STOP_GATE" --fingerprint)"

echo "[1/6] 校验 Codex 配置"
/usr/bin/python3 -m json.tool .codex/hooks.json >/dev/null
/usr/bin/python3 "$VERIFY_STOP_GATE" --validate-config
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$VERIFY_HOOK_TESTS"
test "$(sed -n '2p' .agents/skills/ship-code/SKILL.md)" = "name: ship-code"
grep -q '^  default_prompt: ".*\$ship-code' .agents/skills/ship-code/agents/openai.yaml

echo "[2/6] 校验内置模板"
./script/verify_templates.sh

echo "[3/6] 运行 FewerCore 单元测试"
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme FewerCore \
  -configuration Debug \
  -derivedDataPath "$VERIFY_DERIVED_DATA" \
  SYMROOT="$VERIFY_DERIVED_DATA/Build/Products" \
  OBJROOT="$VERIFY_DERIVED_DATA/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  test | xcbeautify

echo "[4/6] 构建完整 Debug 应用"
xcodebuild \
  -project Fewer.xcodeproj \
  -scheme Fewer \
  -configuration Debug \
  -derivedDataPath "$VERIFY_DERIVED_DATA" \
  SYMROOT="$VERIFY_DERIVED_DATA/Build/Products" \
  OBJROOT="$VERIFY_DERIVED_DATA/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  build | xcbeautify

echo "[5/6] 检查产物和 diff"
VERIFY_APP="$VERIFY_DERIVED_DATA/Build/Products/Debug/Fewer.app"
test -d "$VERIFY_APP"
test -d "$VERIFY_APP/Contents/PlugIns/FewerFinderExtension.appex"
test -d "$VERIFY_APP/Contents/Library/LoginItems/FewerShortcutHelper.app"
git diff --check
git diff --cached --check
/usr/bin/python3 "$VERIFY_STOP_GATE" --check-untracked

VERIFY_FINGERPRINT_AFTER="$(/usr/bin/python3 "$VERIFY_STOP_GATE" --fingerprint)"
if [[ "$VERIFY_FINGERPRINT_BEFORE" != "$VERIFY_FINGERPRINT_AFTER" ]]; then
  echo "验证命令修改了非忽略的工作树内容；请检查并重新运行。" >&2
  exit 1
fi

echo "[6/6] 记录成功验证 receipt"
/usr/bin/python3 "$VERIFY_STOP_GATE" --record-success "$VERIFY_FINGERPRINT_AFTER"

echo "完整验证通过"
