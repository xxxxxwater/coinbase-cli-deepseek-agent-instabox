#!/usr/bin/env bash
# cb-doctor.sh：判级、退出码、JSON 形状、Ed25519 识别
. "$(dirname "$0")/../helper.sh"
setup
DOC="$ROOT/scripts/cb-doctor.sh"
export COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111"
# 测试必须能离线跑：不依赖 api.coinbase.com 的真实响应
export CB_DOCTOR_SKIP_NET=1

mkkey() {  # mkkey <path> <ec|ed25519>
  # PEM 的 BEGIN/END 标记拆开拼，避免仓库里出现完整私钥标记串
  # （secret-scan 会对完整标记报警，拆开后扫描仍然有效）
  local b='-----BEGIN EC PRIVATE' e='-----END EC PRIVATE'
  if [ "$2" = ec ]; then
    printf '{"name":"organizations/o/apiKeys/k","privateKey":"%s KEY-----\\nMHcCAQEE\\n%s KEY-----\\n"}' "$b" "$e" > "$1"
  else
    node -e 'const c=require("crypto");const s=Buffer.concat([c.randomBytes(32),c.randomBytes(32)]);console.log(JSON.stringify({id:"k",privateKey:s.toString("base64")}))' > "$1"
  fi
  chmod 600 "$1"
}

echo "离线开关：出网检查应记为 skip 而不是 fail"
out=$(COINBASE_KEY_FILE="$TESTDIR/ec.json" NODE_OPTIONS=--dns-result-order=ipv4first bash "$DOC" 2>&1)
assert_contains "$out" "已跳过出网检查" "CB_DOCTOR_SKIP_NET=1 时跳过出网检查"
if printf '%s' "$out" | grep -q '✗ net.edge'; then bad "跳过时不应报失败"; else ok "跳过时不报失败"; fi

echo "ECDSA key：key.type 通过"
mkkey "$TESTDIR/ec.json" ec
out=$(COINBASE_KEY_FILE="$TESTDIR/ec.json" NODE_OPTIONS=--dns-result-order=ipv4first bash "$DOC" 2>&1)
assert_contains "$out" "ECDSA" "识别为 ECDSA"
assert_not_contains "$out" "必须换 ECDSA" "不该报 Ed25519 错误"

echo "Ed25519 key：必须明确判失败"
mkkey "$TESTDIR/ed.json" ed25519
out=$(COINBASE_KEY_FILE="$TESTDIR/ed.json" NODE_OPTIONS='' bash "$DOC" 2>&1); rc=$?
assert_contains "$out" "Ed25519" "识别为 Ed25519"
assert_contains "$out" "不支持" "说明不受支持"
assert_exit "$rc" "2" "有失败项时退出码 2"

echo "--json 是合法 JSON 且字段齐全"
COINBASE_KEY_FILE="$TESTDIR/ec.json" bash "$DOC" --json 2>/dev/null > "$TESTDIR/out.json"
assert_eq "$(python3 -c 'import json;d=json.load(open("'$TESTDIR/out.json'"));print("ok" if {"ok","failed","warned","checks"}<=set(d) else "missing")')" "ok" "顶层字段齐全"
assert_eq "$(python3 -c 'import json;d=json.load(open("'$TESTDIR/out.json'"));print(all({"check","status","message"}<=set(c) for c in d["checks"]))')" "True" "每条检查字段齐全"

echo "--quiet 不打印通过的项"
out=$(COINBASE_KEY_FILE="$TESTDIR/ed.json" bash "$DOC" --quiet 2>&1)
assert_not_contains "$out" "✓ env.node" "quiet 隐藏通过项"
assert_contains "$out" "Ed25519" "quiet 仍显示失败项"

echo "关键检查项必须存在"
out=$(COINBASE_KEY_FILE="$TESTDIR/ec.json" bash "$DOC" 2>&1)
for c in env.node cli.coinbase node.ipv4 net.edge key.type api.permissions; do
  assert_contains "$out" "$c" "包含检查 ${c}"
done

finish
