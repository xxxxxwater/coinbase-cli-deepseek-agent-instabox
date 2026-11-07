#!/usr/bin/env python3
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
RISK = ROOT / "scripts/cb-risk.sh"
PROXY = ROOT / "guard/mcp-proxy.mjs"
TRADE = ROOT / "scripts/cb-trade.sh"
SPEC = importlib.util.spec_from_file_location("ledger", ROOT / "scripts/lib/risk-ledger.py")
LEDGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LEDGER)


def request(ident=1, amount=60, name="coinbase_orders_create", **args):
    arguments = dict(product_id="BTC-USD", side="BUY", quote_size=amount)
    arguments.update(args)
    return dict(jsonrpc="2.0", id=ident, method="tools/call",
                params=dict(name=name, arguments=arguments))


class ReservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.journal = self.home / "journal.jsonl"
        self.log = self.home / "calls.jsonl"
        self.log.write_text("")
        self.fake = self.home / "fake.mjs"
        self.fake.write_text('''import fs from "node:fs";
import readline from "node:readline";
readline.createInterface({input: process.stdin}).on("line", (line) => {
  fs.appendFileSync(process.env.FAKE_LOG, line + "\\n");
  const m = JSON.parse(line);
  if (process.env.FAKE_MODE === "crash") process.exit(2);
  if (process.env.FAKE_MODE === "silent") return;
  const reply = process.env.FAKE_MODE === "error" ? {error:{code:-1,message:"unknown result"}} : {result:{success:true}};
  setTimeout(() => process.stdout.write(JSON.stringify({jsonrpc:"2.0",id:m.id,...reply}) + "\\n"), Number(process.env.FAKE_DELAY || 0));
});
''')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("CB_RISK_")}
        self.env.update(CB_CONFIG=str(self.home / "config.json"),
                        CB_REAL_COINBASE=str(self.fake), CB_RISK_BIN=str(RISK),
                        CB_PRODUCTS_BIN=str(self.home / "no-price.sh"),
                        CB_NEWS_P0_FILE=str(self.home / "no-p0.json"),
                        FAKE_LOG=str(self.log), NO_COLOR="1")
        self.config(max_daily_usd=100)

    def config(self, **values):
        Path(self.env["CB_CONFIG"]).write_text(json.dumps(values))

    def cli(self, *args, **env):
        return subprocess.run(["bash", str(RISK), *map(str, args)],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=20)

    def proxy(self, *messages, **env):
        return subprocess.run(["node", str(PROXY)], env=dict(self.env, **env),
                              input="".join(json.dumps(x) + "\n" for x in messages),
                              capture_output=True, text=True, timeout=25)

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()]

    def rows(self):
        return [json.loads(x) for x in self.journal.read_text().splitlines()] if self.journal.exists() else []

    def spent(self):
        with LEDGER.locked(str(self.journal)):
            return LEDGER.usage(LEDGER.read_rows(str(self.journal)))

    def reserve(self, value=60):
        r = self.cli("reserve", "BTC-USD", "BUY", value, "market", "test")
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)["reservation_id"]

    def test_sequential_daily_cap_and_passthrough(self):
        r = self.proxy(request(1), request(2), request(3, name="coinbase_balance"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([x["id"] for x in self.calls()], [1, 3])
        self.assertIn('"id":2,"error"', r.stdout)
        self.assertEqual(self.spent(), (60, 1))

    def test_separate_proxy_processes_race(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            results = list(pool.map(lambda ident: self.proxy(request(ident)), [1, 2]))
        self.assertTrue(all(r.returncode == 0 for r in results))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.spent(), (60, 1))
        self.assertEqual(self.cli("verify").returncode, 0)

    def install_shell_stub(self):
        bindir = self.home / "bin"
        bindir.mkdir()
        coinbase = bindir / "coinbase"
        coinbase.write_text('''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:3] == ["products", "get"]:
    print('{"product_type":"SPOT","price":"100"}')
elif sys.argv[1:3] == ["orders", "create"]:
    with open(os.environ["FAKE_LOG"], "a") as f: f.write('{"id":"shell"}\\n')
    print('{"success":true}')
    sys.exit(int(os.environ.get("SHELL_RC", "0")))
else: print('{}')
''')
        coinbase.chmod(0o755)
        self.env.update(PATH=str(bindir) + os.pathsep + self.env["PATH"],
                        COINBASE_PORTFOLIO_ID="11111111-1111-1111-1111-111111111111")

    def shell(self, *flags, **env):
        return subprocess.run(["bash", str(TRADE), "BTC-USD", "BUY", "60", *flags],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=25)

    def test_shell_and_proxy_share_atomic_budget(self):
        self.install_shell_stub()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            shell = pool.submit(self.shell, "--commit", "--yes")
            proxy = pool.submit(self.proxy, request())
            results = [shell.result(), proxy.result()]
        self.assertEqual(len(self.calls()), 1, [(r.stdout, r.stderr) for r in results])
        self.assertEqual(self.spent(), (60, 1))
        self.assertEqual(self.cli("verify").returncode, 0)

    def test_successful_and_failed_shell_audit_never_double_counts_or_releases(self):
        self.install_shell_stub()
        for status in ("0", "1"):
            with self.subTest(status=status):
                self.journal.unlink(missing_ok=True)
                result = self.shell("--commit", "--yes", SHELL_RC=status)
                self.assertEqual(result.returncode, int(status), result.stderr)
                self.assertEqual(self.spent(), (60, 1))
                self.assertEqual([r["event"] for r in self.rows()], ["reserve", "exec"])

    def test_dry_run_and_paper_do_not_reserve(self):
        self.install_shell_stub()
        self.assertEqual(self.shell().returncode, 0)
        self.assertEqual(self.shell("--paper").returncode, 0)
        self.assertEqual(self.spent(), (0, 0))
        self.assertFalse(self.calls())

    def test_error_silent_crash_and_delayed_response_do_not_release(self):
        for mode in ("error", "silent", "crash", "normal"):
            with self.subTest(mode=mode):
                self.journal.unlink(missing_ok=True)
                self.log.write_text("")
                self.proxy(request(), FAKE_MODE=mode, FAKE_DELAY="30")
                self.assertEqual(self.spent(), (60, 1))
                self.proxy(request(2))
                self.assertEqual(len(self.calls()), 1)

    def test_proxy_kill_after_forward_retains_reservation(self):
        p = subprocess.Popen(["node", str(PROXY)], env=dict(self.env, FAKE_MODE="silent"),
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            p.stdin.write(json.dumps(request()) + "\n")
            p.stdin.flush()
            until = time.monotonic() + 10
            while not self.calls() and time.monotonic() < until:
                time.sleep(0.01)
            self.assertEqual(len(self.calls()), 1)
            p.kill()
            p.communicate(timeout=5)
            self.proxy(request(2))
            self.assertEqual(len(self.calls()), 1)
            self.assertEqual(self.spent(), (60, 1))
        finally:
            if p.poll() is None:
                p.kill()
                p.communicate(timeout=5)

    def test_hourly_cap_and_exact_daily_boundary(self):
        self.config(max_daily_usd=100, max_orders_per_hour=2)
        self.proxy(request(1, 40), request(2, 60), request(3, 1))
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.spent(), (100, 2))
        self.config(max_daily_usd=1000, max_orders_per_hour=2)
        self.proxy(request(4, 1))
        self.assertEqual(len(self.calls()), 2)

    def test_decimal_hour_limit_and_command_names_as_arguments(self):
        self.config(max_orders_per_hour="1.0")
        self.reserve(10)
        self.assertEqual(self.cli("reserve", "BTC-USD", "BUY", 10, "market", "test").returncode, 4)
        # A keyword in an argument is data, not a second command.
        self.assertEqual(self.cli("reserve", "BTC-USD", "reset", 10, "market", "test").returncode, 4)
        self.assertTrue(self.journal.exists())
        self.assertEqual(self.spent(), (10, 1))

    def test_unknown_reservation_survives_midnight_and_blocks_reset(self):
        yesterday = time.time() - 86400
        self.journal.write_text(json.dumps(dict(event="reserve", reservation_id="past", result="pending",
            product="BTC-USD", side="BUY", type="market", notional=60,
            epoch=yesterday, day=time.strftime("%Y-%m-%d", time.localtime(yesterday)))) + "\n")
        self.proxy(request())
        self.assertFalse(self.calls())
        self.assertEqual(self.spent(), (60, 0))
        self.assertEqual(self.cli("reset").returncode, 4)
        self.assertTrue(self.journal.exists())
        self.assertEqual(self.cli("reconcile", "past", "accepted").returncode, 0)
        self.assertEqual(self.spent(), (60, 0))

    def test_explicit_reconciliation_and_reset(self):
        rid = self.reserve()
        self.assertEqual(self.cli("reconcile", rid, "not-submitted").returncode, 0)
        self.assertEqual(self.spent(), (0, 1))  # An admitted attempt still counts.
        self.assertEqual(self.cli("reconcile", rid, "accepted").returncode, 4)
        self.assertEqual(self.cli("reset").returncode, 0)
        self.assertFalse(self.journal.exists())
        self.assertEqual(len(list(self.home.glob("journal.jsonl.*.archived"))), 1)

    def test_corrupt_or_unwritable_ledger_fails_closed(self):
        for malformed in ("not json\n", "{}\n[]\n"):
            self.journal.write_text(malformed)
            self.proxy(request())
            self.assertFalse(self.calls())
        self.journal.unlink()
        self.journal.mkdir()
        self.proxy(request())
        self.assertFalse(self.calls())
        self.journal.rmdir()
        self.journal.write_text("")
        self.journal.chmod(0o400)
        try:
            self.proxy(request())
            self.assertFalse(self.calls())
        finally:
            self.journal.chmod(0o600)

    def test_fsync_failure_is_failure_not_permission(self):
        row = LEDGER.record("reserve", "BTC-USD", "BUY", "market", 60, "pending", extra={"reservation_id":"fsync"})
        with LEDGER.locked(str(self.journal)), mock.patch.object(LEDGER.os, "fsync", side_effect=OSError("test fsync failure")):
            with self.assertRaises(OSError):
                LEDGER.append(str(self.journal), [], row)
        # Even though the caller did not receive permission, uncertain written
        # data remains charged. No rollback can accidentally permit a replay.
        self.assertEqual(self.spent(), (60, 1))

    def test_invalid_amounts_and_limits_fail_closed(self):
        for value in (-1, "NaN", "Infinity", "-Infinity", True, "", 0):
            self.proxy(request(amount=value))
        self.assertFalse(self.calls())
        for limit in ("bad", -1, "NaN", "Infinity", True):
            self.config(max_daily_usd=limit)
            self.proxy(request())
        self.config(max_orders_per_hour=1.5)
        self.proxy(request())
        self.assertFalse(self.calls())

    def test_invalid_tightening_and_corrupt_config_fail_closed(self):
        p0 = self.home / "p0.json"
        p0.write_text(json.dumps(dict(count=1, latest=int(time.time()))))
        self.env["CB_NEWS_P0_FILE"] = str(p0)
        for key, value in (("tighten_factor", "NaN"), ("tighten_factor", "Infinity"),
                           ("tighten_factor", -1), ("tighten_factor", 2),
                           ("tighten_hours", "bad"), ("tighten_hours", 1.5)):
            self.config(max_single_trade_usd=100, **{key: value})
            self.proxy(request(amount=500))
        Path(self.env["CB_CONFIG"]).write_text("{bad json")
        self.proxy(request())
        self.assertFalse(self.calls())

    def test_sub_eight_decimal_usage_is_not_rounded_down(self):
        self.config(max_daily_usd="0.000000001")
        self.reserve("0.0000000006")
        refused = self.cli("reserve", "BTC-USD", "BUY", "0.0000000006", "market", "test")
        self.assertEqual(refused.returncode, 4)
        self.assertEqual(str(self.spent()[0]), "6E-10")

    def test_batches_and_unvalued_tools_fail_closed(self):
        self.proxy([request()], request(name="coinbase_convert_execute"),
                   request(name="coinbase_x402_pay"), request(name="coinbase_orders_close_position"),
                   request(product_id="BTC-EUR"), request(name="coinbase_transfer", currency="BTC", amount=1))
        self.assertFalse(self.calls())

    def test_old_risk_binary_cannot_claim_permission(self):
        old = self.home / "old-risk.sh"
        old.write_text("#!/usr/bin/env bash\necho passed\nexit 0\n")
        self.proxy(request(), CB_RISK_BIN=str(old))
        self.assertFalse(self.calls())

    def test_concurrent_admission_and_audit_chain(self):
        self.config(max_daily_usd=1000)
        def action(i):
            if i % 2:
                return self.cli("reserve", "BTC-USD", "BUY", 10, "market", "test")
            return subprocess.run(["bash", "-c",
                'source scripts/lib/config.sh; source scripts/lib/risk.sh; cb_risk_journal_add preview BTC-USD BUY market 1 ok test'],
                cwd=ROOT, env=self.env, capture_output=True, text=True, timeout=25)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(action, range(12)))
        self.assertTrue(all(r.returncode == 0 for r in results), [r.stderr for r in results])
        self.assertEqual(len(self.rows()), 12)
        self.assertEqual(self.spent(), (60, 6))
        self.assertEqual(self.cli("verify").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
