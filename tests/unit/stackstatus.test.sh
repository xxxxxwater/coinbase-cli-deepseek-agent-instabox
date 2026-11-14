#!/usr/bin/env bash
# Execute only extracted diagnostic/serialization blocks, never the boot/self-heal script.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

source = (pathlib.Path(sys.argv[1]) / 'scripts/coinbase-stack-check.sh').read_text()
check = source[source.index('check() {'):source.index('\nsay "===== boot')]
mcp = source.split('# ---------- 6. MCP 注册 ----------\n', 1)[1].split('# ---------- 7.', 1)[0]
status = source.split('# ---------- 状态文件 ----------\n', 1)[1].split('\nsay "结果:', 1)[0]

class StatusTests(unittest.TestCase):
    def render(self, claude=None, codex=None, special=False, escaped=False):
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(tmp)
            (home / '.codex').mkdir()
            if claude is not None:
                (home / '.claude.json').write_text(claude)
            if codex is not None:
                (home / '.codex/config.toml').write_text(codex)
            # All paths/inputs are explicit positional arguments. No boot prologue,
            # sudo, CLI, accounts, network, configuration sourcing or self-heal runs.
            script = 'set -uo pipefail\nHOME_DIR=$1; STATUS=$2; ver=$3; envname=$4; fail=0; res=()\n' + check
            script += '\n' + mcp
            if special:
                script += '\ncheck 1 "$5"\n'
            script += '\n' + status
            value = 'version "quoted"\\path\nnext\tline\r'
            if not (special or escaped):
                value = 'ordinary'
            p = subprocess.run(['bash', '-c', script, 'test', tmp, str(home / 'status.json'), value, value, value], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return json.loads((home / 'status.json').read_text()), value

    def test_missing(self):
        d, _ = self.render()
        self.assertFalse(d['ok'])
        self.assertEqual(d['checks'], ['mcp(claude=0 codex=0):FAIL'])

    def test_unregistered(self):
        d, _ = self.render('{}', '')
        self.assertFalse(d['ok'])
        self.assertEqual(d['checks'], ['mcp(claude=0 codex=0):FAIL'])

    def test_one_registered(self):
        for c, x, expected in [('{}', '[mcp_servers.coinbase]', '0 codex=1'), ('{"coinbase":{}}', '', '1 codex=0')]:
            with self.subTest(expected=expected):
                d, _ = self.render(c, x)
                self.assertFalse(d['ok'])
                self.assertEqual(d['checks'], ['mcp(claude=' + expected + '):FAIL'])

    def test_registered_and_escaped(self):
        d, value = self.render('{"coinbase":{}}', '[mcp_servers.coinbase]', escaped=True)
        self.assertTrue(d['ok'])
        self.assertEqual(d['checks'], ['mcp:OK'])
        self.assertEqual(d['version'], value)
        self.assertEqual(d['env'], value)
        self.assertIsInstance(d['at'], str)

    def test_check_text_escaped(self):
        d, value = self.render('{"coinbase":{}}', '[mcp_servers.coinbase]', special=True)
        self.assertFalse(d['ok'])
        self.assertEqual(d['checks'], ['mcp:OK', value + ':FAIL'])

unittest.main(argv=['stackstatus'], verbosity=2)
PY
