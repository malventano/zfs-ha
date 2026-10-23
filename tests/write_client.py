#!/usr/bin/env python3
"""zfs-ha: external write client for cutover testing.

Writes synchronized (fsync'd) records to a file on the HA filesystem and can
verify, after a cutover, that every acknowledged write survived.

Usage:
  write_client.py write  --path <file> [--duration 60] [--interval 0.5]
  write_client.py verify --path <file>

Record format: one JSON object per line:
  {"seq": N, "ts": <unix time>, "sha": "<sha256 of seq+ts>"}

verify exits 0 if the sequence is contiguous from 1 with no gaps and all
hashes match; exits 1 otherwise, printing the first gap/corruption found.
"""
import argparse
import hashlib
import json
import os
import sys
import time

def write_mode(path, duration, interval):
    seq = 0
    deadline = time.time() + duration
    with open(path, "a", buffering=1) as f:
        while time.time() < deadline:
            seq += 1
            ts = time.time()
            blob = f"{seq}:{ts:.6f}"
            rec = {"seq": seq, "ts": ts, "sha": hashlib.sha256(blob.encode()).hexdigest()}
            f.write(json.dumps(rec) + "\n")
            f.flush()
            os.fsync(f.fileno())
            time.sleep(interval)
    print(f"wrote {seq} records")
    with open(path + ".seq", "w") as f:
        f.write(str(seq))

def verify_mode(path):
    expected = 0
    if os.path.exists(path + ".seq"):
        with open(path + ".seq") as f:
            expected = int(f.read().strip())
    seen = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"FAIL: corrupt JSON at record {seen+1}: {e}")
                return 1
            seen += 1
            if rec["seq"] != seen:
                print(f"FAIL: sequence gap: expected {seen}, got {rec['seq']}")
                return 1
            blob = f"{rec['seq']}:{rec['ts']:.6f}"
            if hashlib.sha256(blob.encode()).hexdigest() != rec["sha"]:
                print(f"FAIL: hash mismatch at seq {rec['seq']}")
                return 1
    if expected and seen < expected:
        print(f"FAIL: acknowledged {expected} records but only {seen} present "
              f"({expected - seen} lost)")
        return 1
    print(f"PASS: {seen} records, contiguous, all hashes valid")
    return 0

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    w = sub.add_parser("write")
    w.add_argument("--path", required=True)
    w.add_argument("--duration", type=float, default=60)
    w.add_argument("--interval", type=float, default=0.5)
    v = sub.add_parser("verify")
    v.add_argument("--path", required=True)
    args = ap.parse_args()
    if args.mode == "write":
        write_mode(args.path, args.duration, args.interval)
    else:
        sys.exit(verify_mode(args.path))

if __name__ == "__main__":
    main()
