#!/usr/bin/env bash
# 离线执行开机自检的 CLI 检查段，确认写入状态文件的版本和检查结果。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup
source_script="$ROOT/scripts/coinbase-stack-check.sh"

cat > "$STUB_DIR/coinbase" <<'STUB'
#!/usr/bin/env bash
[ "$1" = --version ] || exit 1
printf 'diagnostic on stderr\n' >&2
printf '%s' "$PROBE_OUTPUT"
exit "$PROBE_RC"
STUB
printf '#!/bin/sh\nexit 1\n' > "$STUB_DIR/sudo"
chmod +x "$STUB_DIR/coinbase" "$STUB_DIR/sudo"

{
  cat <<'PROBE'
set -uo pipefail
LOG=$1
STATUS=$2
envname=live
fail=0
res=()
say() { :; }
PROBE
  awk '/^check\(\) \{/{copy=1} /^say "===== boot/{copy=0} copy' "$source_script"
  awk '/^# ---------- 2\. /{copy=1} /^# ---------- 2\.5 /{copy=0} copy' "$source_script"
  awk '/^# ---------- 状态文件/{copy=1} /^say "结果:/{copy=0} copy' "$source_script"
} > "$TESTDIR/probe.sh"

probe() {
  PROBE_RC="$1" PROBE_OUTPUT="$2" bash "$TESTDIR/probe.sh" "$TESTDIR/log" "$TESTDIR/status.json"
  python3 - "$TESTDIR/status.json" <<'PYSTATUS'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    status = json.load(f)
print(status["ok"], status["checks"], repr(status["version"]))
PYSTATUS
}

assert_eq "$(probe 127 '')" "False ['cli:FAIL'] ''" "CLI 失败并在 stderr 报错：标记失败并清空版本"
assert_eq "$(probe 1 'partial output')" "False ['cli:FAIL'] ''" "CLI 失败但有 stdout：不采信部分版本"
assert_eq "$(probe 0 'coinbase 0.0.11')" "True ['cli(coinbase 0.0.11):OK'] 'coinbase 0.0.11'" "CLI 成功：版本只来自 stdout"
assert_eq "$(probe 0 '')" "False ['cli:FAIL'] ''" "CLI 成功但没有版本：标记失败"
assert_contains "$(cat "$TESTDIR/log")" "diagnostic on stderr" "诊断保留在日志"
finish
