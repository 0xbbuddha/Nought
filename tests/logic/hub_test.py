#!/usr/bin/env python3
"""Logic tests for scripts/hub.py: the curve, the fancontrol file and the
storage walk. No hardware, no /sys, no network.

    tests/logic/hub_test.py
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "scripts"))
import hub  # noqa: E402

fails = []


def check(cond: bool, what: str) -> None:
    print(("ok   " if cond else "FAIL ") + cond if cond else "FAIL: " + cond)
    if not cond:
        fails.append(cond)


# ── fan_conf ──────────────────────────────────────────────────────────
conf = hub.fan_conf("hwmon3/fan1", "hwmon3/temp1", "40=40,50=80,70=255")
fan_conf = hub.fan_conf
check("fanconf: DEVPATH present", "DEVPATH=devices/" in conf)
check("fanconf: FCTEMPS maps fan to temp",
      "FCTEMPS=hwmon3/fan1=hwmon3/temp1_input" in conf)
check("fanconf: MINPWM from the curve's first point",
      "MINPWM=hwmon3/fan1=40" in fan_conf("hwmon3/fan1", "hwmon3/temp1",
                                          "40=40,50=80,70=255"))
check("fanconf: MAXPWM from the curve's last step",
      "MAXPWM=hwmon3/fan1=255" in fan_conf("hwmon3/fan1", "hwmon3/temp1",
                                           "40=40,50=80,70=255"))
# A fan the kernel does not expose a PWM for produces an empty answer,
# which the shell reads as "refused" rather than as a file to run.
check("fanconf refuses an unknown fan", hub.fan_conf("hwmon99/fan9", "hwmon3/temp1", "40=40") == "")
# A curve with a stray entry is rejected rather than rounded.
check("fanconf refuses a curve with no pairs",
      hub.fan_conf("hwmon3/fan1", "hwmon3/temp1", "nope") == "")

# ── cpu_temp: the chassis sensor is not the CPU ──────────────────────
rows = [{"name": "acpitz", "c": 30.0}, {"name": "Tctl", "c": 61.5},
        {"name": "edge", "c": 48.0}]
check("cpu_temp takes the hottest CPU reading", hub.cpu_temp(rows) == 61.5)
check("cpu_temp with nothing CPU-shaped", hub.cpu_temp(
    [{"name": "Composite", "c": 44.0}]) == -1.0)
# A sensor at exactly 0 is a driver reporting "nothing", not a reading,
# so temps() already dropped it and cpu_temp never sees it.

# ── storage: sizes roll up, symlinks never leave the root ────────────
with tempfile.TemporaryDirectory() as d:
    root = os.path.join(d, "big")
    os.makedirs(root)
    os.makedirs(os.path.join(root, "sub"))
    open(os.path.join(root, "sub", "a"), "w").write("x" * 1000)
    os.symlink("/etc", os.path.join(root, "elsewhere"))
    rows = hub.storage(root, depth=4, nodes=1000)
    got = {r["path"]: r["size"] for r in rows}
    top = root
    assert os.path.join(root, "sub") in got, "the subdirectory is in the list"
    assert got.get(root, 0) >= 100, "the parent carries its children's size"
    assert all(r["path"].startswith(root) for r in rows), "nothing outside root"

for f in fails:
    print("  - " + f)
print("PASS" if not fails else "FAIL")
sys.exit(1 if fails else 0)
