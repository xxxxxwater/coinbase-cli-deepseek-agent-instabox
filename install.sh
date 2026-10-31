#!/usr/bin/env bash
# install.sh — 把这一套装到一台新机器上
#
# 装什么：Coinbase CLI、四个运维脚本、可选的开机自检 systemd 单元。
# 不装什么：不写 CDP 私钥、不碰用户的 agent 配置、不动已有的 systemd 单元。
#
# 用法:
#   ./install.sh                       # 装到 ~/.local/bin，交互确认
#   ./install.sh --yes                 # 不问，直接装
#   ./install.sh --prefix /usr/local   # 换安装位置
#   ./install.sh --systemd             # 同时装 coinbase-stack.service（需要 sudo）
#   ./install.sh --key-file ~/cdp.json --portfolio <uuid>
#   ./install.sh --skip-cli            # 跳过 npm 全局安装（离线/已装）
#
# 退出码: 0 成功 / 1 环境不满足 / 2 用户取消 / 3 安装过程出错

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

PREFIX="${HOME}/.local"
BIN_DIR=""
WITH_SYSTEMD=0
ASSUME_YES=0
SKIP_CLI=0
KEY_FILE=""
PORTFOLIO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX=${2:?}; shift 2 ;;
    --systemd)   WITH_SYSTEMD=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --skip-cli)  SKIP_CLI=1; shift ;;
    --key-file)  KEY_FILE=${2:?}; shift 2 ;;
    --portfolio) PORTFOLIO=${2:?}; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
  esac
done
BIN_DIR="${PREFIX}/bin"

say()  { printf '%s\n' "$*"; }
step() { printf '\n▶ %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# ---------- 1. 环境检查 ----------
step "检查环境"
command -v bash >/dev/null || die "需要 bash"
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$NODE_MAJOR" -ge 22 ] 2>/dev/null || die "需要 Node.js ≥ 22，当前是 $(node -v 2>/dev/null || echo '未安装')"
say "  node        $(node -v)"
if command -v npm >/dev/null; then
  say "  npm         $(npm -v)"
else
  say "  npm         未安装（只影响 --skip-cli 之外的情况）"
fi
if command -v python3 >/dev/null; then
  say "  python3     $(python3 -V 2>&1 | awk '{print $2}')"
else
  die "需要 python3（脚本用它解析 JSON）"
fi
if command -v curl >/dev/null; then
  say "  curl        有"
else
  die "需要 curl"
fi

# ---------- 2. Coinbase CLI ----------
step "Coinbase CLI"
if [ "$SKIP_CLI" -eq 1 ]; then
  say "  已跳过（--skip-cli）"
elif command -v coinbase >/dev/null; then
  say "  已安装：$(coinbase --version 2>/dev/null | head -1)"
else
  say "  安装 @coinbase/coinbase-cli …"
  if npm install -g @coinbase/coinbase-cli 2>/dev/null; then
    say "  装好了：$(coinbase --version 2>/dev/null | head -1)"
  elif command -v sudo >/dev/null; then
    say "  全局目录不可写，改用 sudo …"
    sudo npm install -g @coinbase/coinbase-cli
    say "  装好了：$(coinbase --version 2>/dev/null | head -1)"
  else
    die "装不上：npm 全局目录不可写且没有 sudo。可以用 npm config set prefix 换目录后重试"
  fi
fi

# ---------- 3. 脚本本体 ----------
step "安装脚本到 ${BIN_DIR}"
mkdir -p "$BIN_DIR/lib"
for f in "$HERE"/scripts/*.sh; do
  [ -f "$f" ] || continue
  install -m 755 "$f" "$BIN_DIR/$(basename "$f")"
done
if [ -d "$HERE/scripts/lib" ]; then
  for f in "$HERE"/scripts/lib/*.sh; do
    [ -f "$f" ] || continue
    install -m 644 "$f" "$BIN_DIR/lib/$(basename "$f")"
  done
fi
# find -exec 而不是 ls|xargs：文件名带空格时不会拆错
say "  已装：$(find "$BIN_DIR" -maxdepth 1 -name '*.sh' -exec basename {} + 2>/dev/null | sort | tr '\n' ' ')"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) say "  ⚠ ${BIN_DIR} 不在 PATH 里，请加一行：
      export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

# ---------- 4. 配置文件 ----------
step "配置"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/coinbase-agent"
CFG="${CFG_DIR}/config.json"
mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR" 2>/dev/null || true

if [ -n "$KEY_FILE" ]; then
  [ -f "$KEY_FILE" ] || die "找不到 key 文件：$KEY_FILE"
  python3 - "$CFG" key_file "$KEY_FILE" <<'PY'
import json, os, sys, tempfile
path, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: d = {}
d[k] = v
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
os.chmod(tmp, 0o600); os.replace(tmp, path)
PY
  say "  已记录 key 文件：$KEY_FILE"
fi

if [ -n "$PORTFOLIO" ]; then
  python3 - "$CFG" portfolio_id "$PORTFOLIO" <<'PY'
import json, os, sys, tempfile
path, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: d = {}
d[k] = v
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write("\n")
os.chmod(tmp, 0o600); os.replace(tmp, path)
PY
  say "  已记录组合：$PORTFOLIO"
fi

if [ ! -f "$CFG" ]; then
  say "  还没有配置文件（之后可以运行 cb-portfolio.sh --save 自动写入）"
fi

# ---------- 5. systemd（可选） ----------
if [ "$WITH_SYSTEMD" -eq 1 ]; then
  step "开机自检单元"
  command -v systemctl >/dev/null || die "这台机器没有 systemd，去掉 --systemd 重试"
  UNIT_SRC="$HERE/systemd/coinbase-stack.service"
  [ -f "$UNIT_SRC" ] || die "找不到 $UNIT_SRC"
  TMP_UNIT=$(mktemp)
  sed -e "s#/data/home#${HOME}#g" \
      -e "s#/usr/local/bin#${BIN_DIR}#g" \
      -e "s#^User=.*#User=$(id -un)#" \
      "$UNIT_SRC" > "$TMP_UNIT"
  if [ "$ASSUME_YES" -eq 0 ]; then
    say "  将要写入 /etc/systemd/system/coinbase-stack.service："
    sed 's/^/    /' "$TMP_UNIT"
    printf '  继续？[y/N] '
    read -r ans </dev/tty
    case "$ans" in y|Y|yes) ;; *) rm -f "$TMP_UNIT"; say "  已取消"; exit 2 ;; esac
  fi
  sudo install -m 644 "$TMP_UNIT" /etc/systemd/system/coinbase-stack.service
  rm -f "$TMP_UNIT"
  sudo systemctl daemon-reload
  sudo systemctl enable --now coinbase-stack.service
  say "  已启用 coinbase-stack.service"
fi

# ---------- 6. 自检 ----------
step "自检"
if [ -x "$BIN_DIR/cb-doctor.sh" ]; then
  set +e
  PATH="${BIN_DIR}:$PATH" "$BIN_DIR/cb-doctor.sh" --quiet
  rc=$?
  set -e
  case "$rc" in
    0) say "  全部通过" ;;
    1) say "  有警告，见上面输出（不影响使用）" ;;
    *) say "  有失败项，先按提示修；不会中断安装" ;;
  esac
fi

step "完成"
say "  下一步："
say "    1) 把 CDP key 装上：cb-activate-key.sh <key.json>"
say "    2) 记下可用组合：cb-portfolio.sh --save"
say "    3) 出问题先跑：cb-doctor.sh"
exit 0
