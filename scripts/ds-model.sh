#!/usr/bin/env bash
# ds-model.sh - point this box's agent CLIs (claude, codex) at a DeepSeek endpoint.
#
#   ds-model.sh --key-file /path/key.txt               # discover models, pick *flash*, configure, test
#   ds-model.sh --key-file /path/key.txt --list-models # probe only, change nothing
#   ds-model.sh --key-file /path/key.txt --model deepseek-chat
#   ds-model.sh --key-file /path/key.txt --base https://api.deepseek.com
#
# Nothing is written unless the key verifies against the endpoint.
set -euo pipefail

BASE="https://api.deepseek.com"
KEY_FILE=""
MODEL=""
LIST_ONLY=0
SKIP_TEST=0
ENV_FILE="/data/home/.config/deepseek/env"
CLAUDE_SETTINGS="/data/home/.claude/settings.json"
CODEX_CONFIG="/data/home/.codex/config.toml"
BEGIN_MARK='# >>> deepseek-model (managed by ds-model.sh)'
END_MARK='# <<< deepseek-model'

usage() { sed -n "2,8p" "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)    KEY_FILE="${2:?}"; shift 2 ;;
    --model)       MODEL="${2:?}";    shift 2 ;;
    --base)        BASE="${2:?}";     shift 2 ;;
    --list-models) LIST_ONLY=1;       shift ;;
    --no-test)     SKIP_TEST=1;       shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

KEY="${DEEPSEEK_API_KEY:-}"
if [ -n "$KEY_FILE" ]; then
  [ -r "$KEY_FILE" ] || { echo "cannot read key file: $KEY_FILE" >&2; exit 66; }
  KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
fi
if [ -z "$KEY" ]; then
  echo "no credential: pass --key-file PATH or set DEEPSEEK_API_KEY" >&2
  exit 64
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== 1. probing $BASE/v1/models"
code="$(curl -sS -m 30 -o "$TMP/models.json" -w '%{http_code}' \
        -H "Authorization: Bearer $KEY" "$BASE/v1/models")"
echo "   HTTP $code"
if [ "$code" != "200" ]; then
  echo "   key rejected or endpoint unavailable; body:" >&2
  head -c 500 "$TMP/models.json" >&2; echo >&2
  exit 1
fi

python3 - "$TMP/models.json" > "$TMP/ids.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ids = [m.get("id") for m in d.get("data", []) if m.get("id")]
print("   models offered: " + (", ".join(ids) if ids else "(empty list)"), file=sys.stderr)
for i in ids:
    print(i)
PY

[ "$LIST_ONLY" = "1" ] && { echo "== --list-models: nothing written"; exit 0; }

if [ -z "$MODEL" ]; then
  MODEL="$(grep -i 'flash' "$TMP/ids.txt" | head -1 || true)"
  if [ -z "$MODEL" ]; then
    n="$(wc -l < "$TMP/ids.txt")"
    if [ "$n" = "1" ]; then MODEL="$(head -1 "$TMP/ids.txt")"; fi
  fi
fi
if [ -z "$MODEL" ]; then
  echo "!! could not pick a model automatically. offered ids:" >&2
  sed 's/^/     /' "$TMP/ids.txt" >&2
  echo "   re-run with --model <id>" >&2
  exit 2
fi
if ! grep -qxF "$MODEL" "$TMP/ids.txt"; then
  echo "!! warning: '$MODEL' is not in the endpoint's model list" >&2
fi
echo "== 2. model = $MODEL"

export DS_KEY="$KEY" DS_MODEL="$MODEL" DS_BASE="$BASE" DS_TMP="$TMP"
export DS_CLAUDE="$CLAUDE_SETTINGS" DS_CODEX="$CODEX_CONFIG" DS_ENV="$ENV_FILE"

echo "== 3. writing claude + codex config"
python3 - <<'PY'
import json, os, stat

key    = os.environ["DS_KEY"]
model  = os.environ["DS_MODEL"]
base   = os.environ["DS_BASE"]
claude = os.environ["DS_CLAUDE"]
codex  = os.environ["DS_CODEX"]
envf   = os.environ["DS_ENV"]

def mode600(p):
    os.chmod(p, stat.S_IRUSR | stat.S_IWUSR)

# ---- Claude Code: settings.json env block
d = {}
if os.path.exists(claude):
    try:
        d = json.load(open(claude))
    except Exception:
        d = {}
d.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": base + "/anthropic",
    "ANTHROPIC_AUTH_TOKEN": key,
    "ANTHROPIC_MODEL": model,
    "ANTHROPIC_SMALL_FAST_MODEL": model,
})
os.makedirs(os.path.dirname(claude), exist_ok=True)
json.dump(d, open(claude, "w"), indent=2)
mode600(claude)
print("   claude  ->", claude, "(env: ANTHROPIC_BASE_URL/%s, ANTHROPIC_MODEL=%s)" % (base + "/anthropic", model))

# ---- Codex: top-level model + provider table, existing mcp_servers preserved
BEGIN = "# >>> deepseek-model (managed by ds-model.sh)"
END   = "# <<< deepseek-model"
existing = ""
if os.path.exists(codex):
    existing = open(codex).read()
kept, skip = [], False
for line in existing.splitlines():
    if line.strip() == BEGIN:
        skip = True
        continue
    if line.strip() == END:
        skip = False
        continue
    if not skip:
        kept.append(line)
block = [
    BEGIN,
    'model = "%s"' % model,
    'model_provider = "deepseek"',
    "",
    "[model_providers.deepseek]",
    'name = "DeepSeek"',
    'base_url = "%s/v1"' % base,
    'env_key = "DEEPSEEK_API_KEY"',
    'wire_api = "responses"',
    END,
    "",
]
os.makedirs(os.path.dirname(codex), exist_ok=True)
open(codex, "w").write("\n".join(block + kept) + "\n")
print("   codex   ->", codex, "(model_providers.deepseek, wire_api=responses)")

# ---- env file so codex's env_key resolves in any shell
os.makedirs(os.path.dirname(envf), exist_ok=True)
open(envf, "w").write('export DEEPSEEK_API_KEY=%s\n' % json.dumps(key))
mode600(envf)
print("   key env ->", envf)
PY

for rc in /data/home/.bashrc /data/home/.profile; do
  touch "$rc"
  if ! grep -qF "$ENV_FILE" "$rc"; then
    printf '\n# deepseek model key\n[ -f %s ] && . %s\n' "$ENV_FILE" "$ENV_FILE" >> "$rc"
    echo "   hooked $rc"
  fi
done

echo "== 4. smoke tests"
oc="$(curl -sS -m 40 -o "$TMP/chat.json" -w '%{http_code}' \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly OK\"}]}" \
  "$BASE/v1/chat/completions")"
echo "   openai-surface  /v1/chat/completions      HTTP $oc"
head -c 300 "$TMP/chat.json"; echo

ac="$(curl -sS -m 40 -o "$TMP/msg.json" -w '%{http_code}' \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly OK\"}]}" \
  "$BASE/anthropic/v1/messages")"
echo "   anthropic-surface /anthropic/v1/messages   HTTP $ac"
head -c 300 "$TMP/msg.json"; echo

if [ "$SKIP_TEST" = "0" ]; then
  if command -v claude >/dev/null 2>&1; then
    echo "   claude -p ..."
    set +e
    timeout 150 claude -p 'reply with exactly OK' 2>&1 | tail -5 | sed 's/^/     /'
    echo "     exit=$?"
    set -e
  fi
  if command -v codex >/dev/null 2>&1; then
    echo "   codex exec ..."
    set +e
    DEEPSEEK_API_KEY="$KEY" timeout 180 codex exec --skip-git-repo-check 'reply with exactly OK' \
      2>&1 | tail -8 | sed 's/^/     /'
    echo "     exit=$?"
    set -e
  fi
fi

echo "== done. new shells pick up the key; for this shell run: . $ENV_FILE"
