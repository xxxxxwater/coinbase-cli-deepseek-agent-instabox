#!/usr/bin/env python3
"""Local, locked risk accounting. Never calls Coinbase or interprets API outcomes."""
import contextlib
import datetime
import decimal
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid


LOCK_ENV = "CB_RISK_LEDGER_LOCK_FD"
decimal.getcontext().prec = 1000


def amount(value):
    if isinstance(value, bool):
        raise ValueError("invalid amount")
    n = decimal.Decimal(str(value))
    if not n.is_finite() or n < 0 or not math.isfinite(float(n)):
        raise ValueError("amount must be finite and non-negative")
    if len(n.as_tuple().digits) > 64 or (n and n.adjusted() < -308):
        raise ValueError("unsupported numeric precision")
    return n


def canonical(row):
    return json.dumps({k: v for k, v in row.items() if k not in ("prev", "h")},
                      ensure_ascii=False, sort_keys=True, separators=(",", ":"))


@contextlib.contextmanager
def locked(path):
    # Lock a stable sidecar, never the replaceable journal inode. A reserve's
    # check subprocess inherits this descriptor, so nested usage/block writes
    # participate in the very same transaction instead of deadlocking.
    lock_path = path + ".lock"
    fd = None
    inherited = False
    try:
        candidate = int(os.environ.get(LOCK_ENV, "-1"))
        st = os.fstat(candidate)
        target = os.stat(lock_path)
        if stat.S_ISREG(st.st_mode) and (st.st_dev, st.st_ino) == (target.st_dev, target.st_ino):
            fd = candidate
            inherited = True
    except (OSError, ValueError):
        pass
    if fd is None:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield fd
    finally:
        if not inherited:
            os.close(fd)


def read_rows(path):
    try:
        with open(path, encoding="utf-8") as f:
            rows = [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []
    previous = ""
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("journal row is not an object")
        if "h" in row:
            expected = hashlib.sha256((previous + canonical(row)).encode()).hexdigest()
            if row.get("prev") != previous or row["h"] != expected:
                raise ValueError("journal hash chain mismatch")
        # Existing unhashed records remain readable; malformed records do not.
        previous = row.get("h", "")
        if row.get("event") in ("exec", "reserve"):
            amount(row.get("notional", 0))
            amount(row.get("epoch", 0))
    reservations(rows)  # Validate references before accepting new exposure.
    return rows


def reservations(rows):
    pending = {}
    resolutions = {}
    for row in rows:
        rid = row.get("reservation_id")
        if row.get("event") == "reserve":
            if not isinstance(rid, str) or not rid or rid in pending:
                raise ValueError("invalid or duplicate reservation")
            pending[rid] = row
        elif row.get("event") == "reconcile":
            if rid not in pending or rid in resolutions or row.get("result") not in ("accepted", "not-submitted"):
                raise ValueError("invalid reservation reconciliation")
            resolutions[rid] = row
        elif row.get("event") == "exec" and rid is not None and rid not in pending:
            raise ValueError("execution references unknown reservation")
    return pending, resolutions


def usage(rows):
    now = time.time()
    today = time.strftime("%Y-%m-%d")
    spent = decimal.Decimal(0)
    count = 0
    pending, resolved = reservations(rows)
    for rid, row in pending.items():
        resolution = resolved.get(rid)
        # Unknown outcomes never expire at midnight or on restart. Accepted
        # reservations count on both admission day and reconciliation day.
        if resolution is None or (resolution["result"] == "accepted" and
                                  today in (row.get("day"), resolution.get("day"))):
            spent += amount(row["notional"])
        if now - float(row.get("epoch", 0)) <= 3600:
            count += 1
    for row in rows:
        if row.get("event") != "exec" or row.get("reservation_id") is not None:
            continue
        if row.get("result") in ("ok", "accepted", "submitted") and row.get("day") == today:
            spent += amount(row.get("notional", 0))
        if now - float(row.get("epoch", 0)) <= 3600:
            count += 1
    return spent, count


def record(event, product, side, kind, notional, result, reason="", extra=None):
    row = dict(ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               epoch=int(time.time()), day=time.strftime("%Y-%m-%d"),
               event=event, product=product, side=side, type=kind,
               notional=str(amount(notional)), result=result)
    if reason:
        row["reason"] = reason
    if extra:
        if not isinstance(extra, dict) or set(extra) & set(row) or set(extra) & {"h", "prev"}:
            raise ValueError("invalid journal metadata")
        row.update(extra)
    return row


def append(path, rows, row):
    row["prev"] = rows[-1].get("h", "") if rows else ""
    row["h"] = hashlib.sha256((row["prev"] + canonical(row)).encode()).hexdigest()
    # Validate accounting semantics before the append, then persist before the
    # caller may forward an order. A failed fsync is an uncertain reservation,
    # never permission to submit or an excuse to remove the record.
    reservations(rows + [row])
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
        f.flush()
        os.fsync(f.fileno())
    directory = os.open(str(Path(path).parent), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def main():
    command, path, *args = sys.argv[1:]
    if command == "validate":
        # Validate before shell comparisons, including values from env/config.
        amount(args[0])
        config = Path(args[6])
        if config.exists():
            with config.open(encoding="utf-8") as f:
                if not isinstance(json.load(f), dict):
                    raise ValueError("risk configuration must be an object")
        for value in args[1:6]:
            if value:
                amount(value)
        if args[3] and amount(args[3]) != amount(args[3]).to_integral_value():
            raise ValueError("hourly limit must be an integer")
        if amount(args[4]) > 1:
            raise ValueError("tightening factor must be between zero and one")
        if amount(args[5]) != amount(args[5]).to_integral_value() or amount(args[5]) > 87600:
            raise ValueError("tightening hours must be an integer up to 87600")
        return
    with locked(path) as fd:
        rows = read_rows(path)
        if command == "usage":
            spent, count = usage(rows)
            print(f"{format(spent, 'f') if spent.as_tuple().exponent < -8 else format(spent, '.8f')} {count}")
        elif command == "append":
            event, product, side, kind, notional, result, reason, extra = args
            append(path, rows, record(event, product, side, kind, notional, result,
                                      reason, json.loads(extra) if extra else None))
        elif command == "reserve":
            product, side, notional, kind, source = args
            amount(notional)
            env = dict(os.environ, **{LOCK_ENV: str(fd)})
            check = Path(__file__).resolve().parent.parent / "cb-risk.sh"
            checked = subprocess.run(["bash", str(check), "check", product, side, notional, kind],
                                     env=env, pass_fds=(fd,), capture_output=True, text=True, timeout=12)
            if checked.returncode:
                print(checked.stdout + checked.stderr, file=sys.stderr, end="")
                raise SystemExit(checked.returncode)
            # The check may append a block on failure. Success never appends;
            # read again to detect any unexpected ledger change before debit.
            rows = read_rows(path)
            rid = str(uuid.uuid4())
            append(path, rows, record("reserve", product, side, kind, notional, "pending",
                                      "Persisted before forwarding; outcome requires reconciliation",
                                      {"reservation_id": rid, "source": source}))
            print(json.dumps({"reservation_id": rid, "status": "reserved"}))
        elif command == "reconcile":
            rid, outcome = args
            pending, resolved = reservations(rows)
            if outcome not in ("accepted", "not-submitted") or rid not in pending or rid in resolved:
                raise ValueError("unknown/already reconciled reservation or invalid outcome")
            row = pending[rid]
            append(path, rows, record("reconcile", row["product"], row["side"], row["type"],
                                      row["notional"], outcome, "Operator reconciliation",
                                      {"reservation_id": rid}))
            print("Reservation reconciled: " + rid)
        elif command == "reset":
            pending, resolved = reservations(rows)
            if pending.keys() - resolved.keys():
                raise ValueError("unresolved reservations remain; reconcile exchange truth before reset")
            if rows:
                stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
                os.rename(path, path + "." + stamp + ".archived")
                print("当日账本已归档，限额计数从 0 开始（记录没删）")
            else:
                print("账本还是空的，不需要清零")
        else:
            raise ValueError("unknown ledger command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, decimal.InvalidOperation, subprocess.SubprocessError) as exc:
        print("风控账本不可用，拒绝操作: " + str(exc), file=sys.stderr)
        raise SystemExit(4)
