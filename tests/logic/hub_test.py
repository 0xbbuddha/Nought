#!/usr/bin/env python3
"""Logic tests for scripts/hub.py: the curve, the fancontrol file and the
storage walk. No hardware, no /sys, no network.

    tests/logic/hub_test.py
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "scripts"))
import hub  # noqa: E402

fails = []


def check(what: str, cond: bool) -> None:
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)


# ── fan_conf ──────────────────────────────────────────────────────────
# A fake sysfs tree, not the real one: fan_conf() checks path existence
# on disk, and the original version of this test read the machine's own
# /sys/class/hwmon/hwmon3 - whatever that happened to be. Passed on
# boards where hwmon3 is a fan, failed on this one, where it is a USB-C
# power sensor. class/hwmon/hwmon3 is a symlink into devices/, the way
# the kernel actually lays it out, so the DEVPATH check means something.
with tempfile.TemporaryDirectory() as sysroot:
    sysroot = os.path.realpath(sysroot)
    real_dir = os.path.join(sysroot, "devices", "platform", "fakeboard", "hwmon", "hwmon3")
    os.makedirs(real_dir)
    open(os.path.join(real_dir, "pwm1"), "w").close()
    open(os.path.join(real_dir, "temp1_input"), "w").close()
    with open(os.path.join(real_dir, "name"), "w") as f:
        f.write("fakechip")
    hwmon_class = os.path.join(sysroot, "class", "hwmon")
    os.makedirs(hwmon_class)
    os.symlink(real_dir, os.path.join(hwmon_class, "hwmon3"))

    def fan_conf(fan_id: str, temp_id: str, curve: str) -> str:
        return hub.fan_conf(fan_id, temp_id, curve, sys_root=sysroot)

    conf = fan_conf("hwmon3/fan1", "hwmon3/temp1", "40=40,50=80,70=255")
    check("fanconf: DEVPATH present", "DEVPATH=devices/" in conf)
    check("fanconf: FCTEMPS maps fan to temp",
          "FCTEMPS=hwmon3/fan1=hwmon3/temp1_input" in conf)
    check("fanconf: MINPWM from the curve's first point",
          "MINPWM=hwmon3/fan1=40" in conf)
    check("fanconf: MAXPWM from the curve's last step",
          "MAXPWM=hwmon3/fan1=255" in conf)
    # A fan the kernel does not expose a PWM for produces an empty
    # answer, which the shell reads as "refused" rather than a file to run.
    check("fanconf refuses an unknown fan", fan_conf("hwmon99/fan9", "hwmon3/temp1", "40=40") == "")
    # A curve with a stray entry is rejected rather than rounded.
    check("fanconf refuses a curve with no pairs", fan_conf("hwmon3/fan1", "hwmon3/temp1", "nope") == "")

# ── main()'s own CLI dispatch, not just the function ─────────────────
# fan_conf() being right is not the same as `hub.py fanconf <fan> <temp>
# <curve>` ever reaching it: main()'s own argv count gate missed by one,
# and every call this script ever makes (exactly three arguments after
# "fanconf") fell through to the catch-all "[]" silently - the function
# tests above never touch main() at all, so they never saw it.
out = subprocess.run(
    [sys.executable, str(HERE.parent.parent / "scripts" / "hub.py"),
     "fanconf", "bogus/fan1", "bogus/temp1", "40=40"],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5).stdout
check("fanconf is dispatched by main(), not swallowed by the catch-all",
      out.strip() != "[]")

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
    assert os.path.join(root, "sub") in got, "the subdirectory is in the list"
    assert got.get(root, 0) >= 100, "the parent carries its children's size"
    assert all(r["path"].startswith(root) for r in rows), "nothing outside root"

for f in fails:
    print("  - " + f)
print("PASS" if not fails else "FAIL")
sys.exit(1 if fails else 0)
