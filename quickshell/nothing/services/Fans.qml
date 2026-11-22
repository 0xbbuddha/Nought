pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import ".."

// Fan control, and the guard rails around it.
//
// Reading a fan is safe. Writing one is the one place this shell touches
// hardware, so it is gated three ways: the kernel must already be in
// manual mode (pwm_enable == 1), fancontrol must be installed, and a
// dialogue must have been answered. A mode of 2 means the board's own
// curve is in charge, and writing into that is the one way to make a fan
// oscillate between two controllers, so the switch stays off and says so
// instead of writing into it.
//
// A curve is a list of { t, p } pairs, ascending. hub.py turns it into
// fancontrol's own file, and fancontrol is what drives the fan: the
// shell never writes a PWM register itself.
Singleton {
    id: root

    // hub.py's fan rows, as they came. Reading is free, and a probe never
    // writes from it.
    readonly property var list: Hub.hw?.fans ?? []
    readonly property int count: list.length
    readonly property bool anyDrivable: list.some(f => f.drivable)
    property bool hasFancontrol: false
    property bool hasPwm: false
    property string fault: ""
    property bool applying: false
    property bool ready: false

    // The fan the page edits: the one chosen, or the first the kernel
    // will let us drive.
    readonly property string fan: {
        const rows = Hub.fans;
        if (Config.fanId !== "" && rows.some(f => f.id === Config.fanId))
            return Config.fanId;
        return rows.find(f => f.drivable)?.id ?? "";
    }

    // Sorted, de-duplicated, clamped at both ends. A curve carrying a PWM
    // of 300 would be read by fancontrol as 255 and by us as 300, and the
    // difference would be invisible until it mattered.
    readonly property var curve: clean(Config.fanCurve)

    // The PWM a curve would pick at a temperature. A reading off the ends
    // of the table must not park the fan at zero on a hot day.
    function curveAt(curve: var, temp: real): int {
        const rows = clean(curve);
        if (rows.length === 0 || !Number.isFinite(temp))
            return -1;
        if (temp <= rows[0].t) return rows[0].p;
        const last = rows[rows.length - 1];
        if (temp >= last.t) return last.p;
        for (let i = 0; i < rows.length - 1; i++) {
            const a = rows[i], b = rows[i + 1];
            if (temp <= b.t) {
                const span = b.t - a.t;
                const share = span <= 0 ? 0 : (temp - a.t) / span;
                return Math.round(a.p + share * (b.p - a.p));
            }
        }
        return last.p;
    }

    // Sorted, de-duplicated, both ends inside 0-110 and 0-255. A curve
    // carrying a PWM of 300 would be read by fancontrol as 255 and by us
    // as 300, and the difference would be invisible until it mattered.
    function clean(curve: var): var {
        const seen = [];
        for (const p of (curve ?? [])) {
            if (!p || !Number.isFinite(p.t) || !Number.isFinite(p.p)) continue;
            const t = Math.max(0, Math.min(110, Math.round(p.t)));
            const value = Math.max(0, Math.min(255, Math.round(p.p)));
            const hit = seen.find(s => s.t === t);
            if (hit) hit.p = value;
            else seen.push({ t: t, p: value });
        }
        seen.sort((a, b) => a.t - b.t);
        return seen;
    }

    function saveCurve(curve: var): void {
        Config.fanCurve = clean(curve);
        Config.save();
        if (Config.fanEnabled && Config.fanApply) apply();
    }

    // The sensor is picked from the fan's own chip: the one on the same
    // board is the one that moves with it, and an unrelated sensor gives
    // a curve that never reaches its ceiling.
    function pickTemp(): string {
        const base = root.fan.split("/")[0];
        const rows = Hub.temps;
        return (rows.find(t => t.id.startsWith(base + "/")) ?? rows[0] ?? {}).id ?? "";
    }

    function apply(): void {
        root.fault = "";
        const fan = Hub.fans.find(f => f.id === root.fan);
        if (!fan || fan.pwmPath === "") {
            root.fault = "no fan the kernel exposes a PWM for";
            return;
        }
        if (!fan.drivable) {
            root.fault = "the board's own curve owns this fan";
            return;
        }
        const rows = clean(Config.fanCurve);
        if (rows.length < 2) {
            root.fault = "a curve needs two points";
            return;
        }
        const temp = pickTemp();
        if (temp === "") {
            root.fault = "no temperature sensor to drive it from";
            return;
        }
        root.applying = true;
        builder.command = ["python3", Quickshell.shellPath("../../scripts/hub.py"),
                           "fanconf", fan.id, temp.id,
                           rows.map(p => p.t + "=" + p.p).join(",")];
        builder.running = true;
    }

    // Releasing is the same dialogue: stop fancontrol, and the board's
    // own curve takes over again. Its own process, not pkexec reused
    // with a different command swapped in - a release that ran after an
    // apply queued up would otherwise find pkexec already holding this
    // command and never the one that starts fancontrol again.
    function release(): void {
        stopper.command = ["pkexec", "sh", "-c", 'pkill -x fancontrol 2>/dev/null || true'];
        stopper.running = true;
    }

    function toggle(): void {
        if (Config.fanEnabled && Config.fanApply) apply();
        else release();
    }

    // ── Build and run ─────────────────────────────────────────────────
    // hub.py's answer is fancontrol's own file, already validated. An
    // empty one means it refused this fan: no PWM, or a sensor on another
    // chip, and that reads as a message rather than as a dialogue that
    // cannot do anything.
    NProcess {
        id: builder
        quiet: true
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "") {
                    root.applying = false;
                    root.fault = "hub.py refused this fan: no PWM, or the sensor "
                        + "is on another chip";
                    return;
                }
                writer.command = ["sh", "-c",
                    'conf="$HOME/.config/nothing/fan-control.conf"'
                    + ' && mkdir -p "$(dirname "$conf")"'
                    + ' && umask 077 && printf "%s" "$1" > "$conf"',
                    "fan-conf", text];
                writer.running = true;
            }
        }
    }

    // Writes the file as the user, no root needed for that part - only
    // starting fancontrol touches a register.
    NProcess {
        id: writer
        quiet: true
        onExited: (code) => {
            if (code !== 0) {
                root.applying = false;
                root.fault = "could not write the fan-control file";
                return;
            }
            starter.running = true;
        }
    }

    NProcess {
        id: starter
        quiet: true
        command: ["pkexec", "sh", "-c",
            'conf="$HOME/.config/nothing/fan-control.conf"'
            + ' && fancontrol -c "$conf" >/dev/null 2>&1 & sleep 1;'
            + ' pgrep -x fancontrol >/dev/null']
        onExited: (code) => {
            root.applying = false;
            if (code !== 0)
                root.fault = "fancontrol could not start - the dialogue was "
                    + "refused, or the board refused the file";
        }
    }

    NProcess {
        id: stopper
        quiet: true
        command: []
    }
}
