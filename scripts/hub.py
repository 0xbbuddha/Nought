#!/usr/bin/env python3
"""One-shot hardware probe for Settings > Hub, Fans and Storage.

    hub.py hw                        temperatures, fans, GPU, load, memory
    hub.py storage <path> [d] [n]    biggest directories under a path
    hub.py palette <image> [count]   dominant colours of a picture
    hub.py fanconf <fan> <temp> <t=p,t=p,...>   a fancontrol.conf, on stdout

Nothing here writes to hardware, and nothing here follows a symlink. The
fan config is generated, not applied: fancontrol -c is what drives the
fan, and only fancontrol -c, because a second writer for the same
registers is the one way to make a fan oscillate.
"""
import glob
import json
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image  # type: ignore
except ImportError:
    Image = None

CHIPS: dict = {}


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def read_int(path: str, default: int = 0) -> int:
    try:
        return int(read_text(path).split()[0])
    except (ValueError, IndexError):
        return default


def chip_name(hwmon: str) -> str:
    if hwmon not in CHIPS:
        CHIPS[hwmon] = read_text(f"{hwmon}/name")
    return CHIPS[hwmon]


def temps() -> list:
    """Every temperature channel, labelled the way the kernel labels it.

    A channel that reads 0 or an absurd value is dropped: a driver that
    has nothing to report prints 0, and a bar that sits at 0 reads as a
    fault, not as a fan that is not spinning.
    """
    out = []
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        chip = chip_name(hw)
        for path in sorted(glob.glob(f"{hw}/temp*_input")):
            n = os.path.basename(path)[4:].split("_")[0]
            c = read_int(path, 0) / 1000.0
            if not (0.0 < c < 150.0):
                continue
            label = read_text(f"{hw}/temp{n}_label")
            out.append({"id": f"{os.path.basename(hw)}/temp{n}",
                        "name": label or chip or "sensor", "c": round(c, 1)})
    return out


def fans() -> list:
    """Fans with their RPM, their PWM and the mode it is in.

    `drivable` is true only when the kernel exposes a PWM and its own
    mode is already 1 (manual). Mode 0 is full speed whatever we write
    and mode 2 is the driver's own curve, so ours would fight it.
    """
    out = []
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        chip = chip_name(hw)
        base = os.path.basename(hw)
        for path in sorted(glob.glob(f"{hw}/fan[0-9]*_input")):
            n = os.path.basename(path)[3:].split("_")[0]
            pwm_path = f"{hw}/pwm{n}"
            has_pwm = os.path.isfile(pwm_path)
            mode = read_int(f"{pwm_path}_enable", -1) if has_pwm else -1
            label = read_text(f"{hw}/fan{n}_label")
            out.append({
                "id": f"{base}/fan{n}",
                "name": label or f"{chip} {n}" if chip else f"fan {n}",
                "rpm": read_int(path, 0),
                "pwm": read_int(pwm_path, -1) if has_pwm else -1,
                "mode": mode,
                "pwmPath": pwm_path if has_pwm else "",
                "drivable": bool(has_pwm and mode == 1),
            })
    return out


def gpu() -> list:
    """Cards the kernel exposes, with the counters they publish.

    An NVIDIA card reports its own utilisation and memory through
    nvidia-smi when that is present; amdgpu reports through sysfs; an
    iGPU reports neither, and shows as a temperature only.
    """
    out = []
    for card in sorted(glob.glob("/sys/class/drm/card[0-9]")):
        dev = f"{card}/device"
        if not os.path.isdir(dev):
            continue
        vram_used = read_int(f"{dev}/mem_info_vram_used", -1)
        vram_total = read_int(f"{dev}/mem_info_vram_total", -1)
        name = read_text(f"{dev}/product_name") or read_text(f"{dev}/label")
        out.append({
            "id": os.path.basename(card),
            "name": name or os.path.basename(card),
            "busy": read_int(f"{card}/gpu_busy_percent", -1),
            "vramUsed": round(vram_used / 1048576) if vram_used > 0 else -1,
            "vramTotal": round(vram_total / 1048576) if vram_total > 0 else 0,
            "kind": "amdgpu" if vram_used > 0 else "drm",
        })
    return out


def gamemode() -> int:
    """How many programs asked gamemoded to go fast. -1: it is not up."""
    busctl = shutil.which("busctl")
    if busctl is None:
        return -1
    try:
        out = subprocess.run(
            ["busctl", "--user", "get-property", "com.feralinteractive.GameMode",
             "/com/feralinteractive/GameMode", "org.feralinteractive.GameMode",
             "ClientCount"],
            text=True, timeout=4, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL).stdout.strip()
        return int(out.rsplit(" ", 1)[1])
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return -1


def mem() -> dict:
    total = available = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                key, _, rest = line.partition(":")
                if key == "MemTotal":
                    total = int(rest.strip().split()[0])
                elif key in ("MemAvailable", "MemFree"):
                    available += int(rest.strip().split()[0])
    except (OSError, ValueError):
        return {}
    return {"memUsedKb": max(0, total - available), "memTotalKb": total}


def cpu_temp(rows: list) -> float:
    """The hottest reading that belongs to a CPU, or -1. The chassis
    sensor is left out: it follows the lid, not the load."""
    best = -1.0
    for t in rows:
        name = t["name"].lower()
        if "cpu" in name or "core" in name or "package" in name or name.startswith("acpi"):
            best = max(best, t["c"])
    return best


def _walk(root: str, depth: int, nodes: int) -> list:
    """One stat per entry, symlinks skipped.

    A directory that links back to / would otherwise be walked twice and
    counted twice, so the walk never follows one.
    """
    out: dict = {}
    visited = {"n": 0}

    def walk(path: str, level: int):
        if level <= 0 or visited["n"] > nodes:
            return
        try:
            entries = list(os.scandir(path))
        except OSError:
            return
        for entry in entries:
            visited["n"] += 1
            if visited["n"] > nodes:
                return
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    out[entry.path] = 0
                    walk(entry.path, level - 1)
                elif entry.is_file(follow_symlinks=False):
                    out[entry.path] = entry.stat(follow_symlinks=False).st_size
            except OSError:
                continue

    walk(root, depth)
    # The root itself is in the list: a walk that only reports children
    # has no row for the directory the user asked about, which is the one
    # row the page wants.
    out[root] = 0
    # Every file's size rolls up to each directory above it. The walk has
    # already visited those, so this is one pass over the names produced.
    for path, size in list(out.items()):
        if size == 0:
            continue
        parent = os.path.dirname(path)
        while parent and parent.startswith(root):
            if parent in out:
                out[parent] += size
            up = os.path.dirname(parent)
            if up == parent:
                break
            parent = up
    # Directories that ended empty are dropped rather than shown as
    # zero: zero reads as a bug, an empty directory reads as itself.
    return sorted(({"path": p, "size": s} for p, s in out.items() if s > 0),
                  key=lambda r: -r["size"])


def storage(root: str, depth: int = 4, nodes: int = 60000) -> list:
    return _walk(root, depth, nodes)


def palette(image: str, count: int = 5) -> list:
    """The picture's dominant colours, darkest first.

    Pillow's median cut is the same first step matugen does, without the
    dependency. Without Pillow the command prints nothing, and the shell
    says so, rather than carrying a second quantiser.
    """
    if Image is None:
        return []
    try:
        img = Image.open(image).convert("RGB")
        img.thumbnail((96, 96))
        q = img.quantize(colors=max(2, count), method=Image.MEDIANCUT)
        pal = q.getpalette() or []
        rows = []
        for freq, idx in (q.getcolors(maxcolors=1024) or []):
            r, g, b = pal[idx * 3:idx * 3 + 3]
            rows.append({"hex": "#%02x%02x%02x" % (r, g, b),
                         "l": 0.2126 * r + 0.7152 * g + 0.0722 * b})
        rows.sort(key=lambda c: c["l"])
        return rows[:count]
    except Exception:
        return []


def fan_conf(fan_id: str, temp_id: str, curve: str) -> str:
    """A fancontrol.conf for one fan and one temperature sensor.

    `curve` is "temp=pwm,temp=pwm", ascending. Nothing is written here:
    the caller writes the file, and fancontrol -c is what drives the
    fan. Its own format is used unchanged, because a second writer on
    the same register is the one way to make a fan oscillate.
    """
    base = f"/sys/class/hwmon/{fan_id.split('/')[0]}"
    n = fan_id.split("fan")[1] if "fan" in fan_id else ""
    if not os.path.isdir(base) or not n.isdigit():
        return ""
    pwm_path = f"{base}/pwm{n}"
    if not os.path.isfile(pwm_path):
        return ""
    temp_path = f"/sys/class/hwmon/{temp_id}_input"
    if not os.path.isfile(temp_path):
        return ""
    pairs = []
    for step in curve.split(","):
        t, _, p = step.partition("=")
        if t.strip().isdigit() and p.strip().isdigit():
            pairs.append((int(t), int(p.strip())))
    if not pairs:
        return ""
    pairs.sort()
    # DEVPATH is fancontrol's identity for the device: the path under
    # /sys it hangs off, minus the hwmon number, which the kernel
    # reassigns on boot.
    real = os.path.realpath(base)
    if not real.startswith("/sys/"):
        return ""
    devpath = real[len("/sys/"):]
    tail = f"/hwmon/{fan_id.split('/')[0]}"
    if devpath.endswith(tail):
        devpath = devpath[: -len(tail)]
    name = chip_name(base)
    lines = [
        "# Written by the Nothing shell (Settings > Hub > Fans).",
        "# fancontrol follows this while it runs; stopping it releases the",
        "# fan back to whatever the board's own curve does.",
        "INTERVAL=10",
        f"DEVPATH={devpath}",
        f"DEVNAME={name}",
        f"FCTEMPS={fan_id}={temp_id}_input",
        f"FCFANS={fan_id}={fan_id}/fan{n}_input".replace("/fan"+n+"/fan"+n, "/fan"+n),
        f"MINTEMP={fan_id}={pairs[0][0]}",
        f"MAXTEMP={fan_id}={pairs[-1][0]}",
        f"MINPWM={fan_id}={pairs[0][1]}",
        f"MAXPWM={fan_id}={pairs[-1][1]}",
	]
    return "\n".join(lines)


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "hw"
    if cmd == "hw":
        rows = temps()
        print(json.dumps({"temps": rows, "fans": fans(), "gpu": gpu(),
                          "gamemode": gamemode(), "cpuTemp": cpu_temp(rows), **mem()}))
    elif cmd == "storage" and len(sys.argv) > 2:
        depth = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 4
        nodes = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4].isdigit() else 60000
        print(json.dumps(storage(sys.argv[2], depth, nodes)))
    elif cmd == "palette" and len(sys.argv) > 2:
        n = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 5
        print(json.dumps(palette(sys.argv[2], n)))
    elif cmd == "fanconf" and len(sys.argv) > 5:
        # hub.py fanconf <hwmonX/fanN> <hwmonY/tempZ> <t=p,t=p,...>
        print(fan_conf(sys.argv[2], sys.argv[3], sys.argv[4]))
    else:
        print("[]")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
