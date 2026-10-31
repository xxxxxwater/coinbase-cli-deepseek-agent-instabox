#!/usr/bin/env bash
# 防回归：bash 里 `$VAR` 紧跟一个非 ASCII 字符（中文标点、全角括号…）时，
# macOS 自带的 bash 3.2 会把多字节字符的头几个字节当成变量名的一部分，
# 于是报 `perms，: unbound variable` —— 在 Linux 的 bash 5 上却是好的。
#
# 这个坑在这个仓库里踩了四次（cb-products.sh 两次、cb-config.sh 一次、还有一次在
# 参数展开 `${VAR:+（...）}` 里）。靠读代码看不出来，所以做成断言：
# 只要 `$VAR` 后面直接跟非 ASCII 字节，就是 bug，必须写成 `${VAR}`。
set -uo pipefail
. "$(dirname "$0")/../helper.sh"
setup

SCAN="$TESTDIR/scan.py"
cat > "$SCAN" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
files = sorted(
    [p for p in (root / "scripts").rglob("*.sh")]
    + [p for p in root.glob("*.sh")]        # install.sh / uninstall.sh / 以后新增的
    + [p for p in (root / "tests").rglob("*.sh")]
)
files = [f for f in files if f.exists()]
hits = []
for f in files:
    for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        for m in pat.finditer(line):
            hits.append((str(f.relative_to(root)), i, m.group(0), line[m.end()], line.strip()[:90]))
for h in hits:
    print(f"{h[0]}:{h[1]}: {h[2]} 紧跟 {h[3]!r}  |  {h[4]}")
print(f"--count {len(hits)}")
print(f"--files {len(files)}")
PY

out=$(python3 "$SCAN" "$ROOT" 2>&1)
n=$(printf '%s\n' "$out" | awk '/^--count /{print $2}')

nfiles=$(printf '%s\n' "$out" | awk '/^--files /{print $2}')
if [ "${nfiles:-0}" -ge 15 ]; then ok "扫描器覆盖了 $nfiles 个脚本"; else bad "只扫到 $nfiles 个脚本，可能漏了目录"; fi
assert_eq "$n" "0" "仓库里没有「\$VAR 紧跟非 ASCII」的写法"

if [ "${n:-0}" != "0" ]; then
  printf '%s\n' "$out" | grep -v '^--' | sed 's/^/        /' >&2
  bad "上面这些地方要改成 \${VAR}（bash 3.2 会把中文标点吃进变量名）"
fi

# 扫描器本身也得有效：造一个已知违规的文件，它必须报出来
mkdir -p "$TESTDIR/repo/scripts"
{ printf '#!/usr/bin/env bash\n'; printf 'echo "%s，bar"\n' '$FOO'; } > "$TESTDIR/repo/scripts/bad.sh"
printf '#!/usr/bin/env bash\necho "${FOO}，bar"\n' > "$TESTDIR/repo/scripts/good.sh"
printf '#!/usr/bin/env bash\necho ok\n' > "$TESTDIR/repo/install.sh"
out2=$(python3 "$SCAN" "$TESTDIR/repo" 2>&1)
n2=$(printf '%s\n' "$out2" | awk '/^--count /{print $2}')
assert_eq "$n2" "1" "扫描器能抓到违规写法（并且只抓那一处）"
assert_contains "$out2" "bad.sh" "扫描器指名道姓"
assert_not_contains "$out2" "good.sh" "扫描器不误报 \${VAR} 写法"

finish
