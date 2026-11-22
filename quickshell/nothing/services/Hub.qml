pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import ".."

// The gaming hub: sessions, hardware, and what the overlays need.
//
// Two jobs, one service. The sessions are Hyprland's windows filtered
// through a watch list; the hardware is one pass through scripts/hub.py,
// which reads /sys/class/hwmon and the GPU card's own sysfs. lm-sensors
// is not required to see them - it reads the same files - so an install
// without it shows numbers and no package name.
//
// Nothing here writes. Writing a fan's PWM is Fans.qml's job, and it
// only ever goes through a dialogue.
//
// No probe runs unless something is looking: the game bar, this page, or
// the hub widget on the game canvas. A closed panel costs nothing, which
// is the same rule Sys.qml follows for its disk probe.
Singleton {
    id: root

    property bool ready: false
    property var hw: null            // hub.py hw's own object
    property bool probing: false
    property var tools: ({})

    readonly property var temps: hw?.temps ?? []
    readonly property var fans: hw?.fans ?? []
    readonly property var gpus: hw?.gpu ?? []
    readonly property bool hasGpu: gpus.length > 0
    // The GPU card's own sensor, which amdgpu reads and nvidia-smi
    // reports. An iGPU without one is -1, and the widget says so.
    readonly property real gpuTemp: {
        for (const g of gpus)
            if (g.temp !== undefined) return g.temp;
        return -1;
    }
    // The card the hub drives: the one with a busy counter, or the
    // first the kernel lists.
    readonly property var gpu: gpus[0] ?? null
    readonly property int vramUsed: gpu?.vramUsed ?? -1
    readonly property int vramTotal: gpu?.vramTotal ?? 0
    readonly property real cpuTemp: hw?.cpuTemp ?? -1
    readonly property int memUsedKb: hw?.memUsedKb ?? 0
    readonly property int memTotalKb: hw?.memTotalKb ?? 0

    // -1 when gamemoded is not on the machine, 0 when it is running with
    // nothing to boost, n when it is boosting n programs.
    property int gamemode: hw?.gamemode ?? -1
    readonly property bool hasGamemode: gamemode >= 0

    readonly property bool hasFan: fans.length > 0
    readonly property bool hasFancontrol: tools.fancontrol ?? false
    readonly property bool hasMangohud: tools.mangohud ?? false
    readonly property bool hasAmdgpuTop: tools.amdgpu_top ?? false

    // Sessions: the windows whose class matches the watch list.
    readonly property var sessions: {
        const out = [];
        for (const t of (Hyprland.toplevels?.values ?? [])) {
            const c = String(t.lastIpcObject?.class ?? "").toLowerCase();
            if (c === "" || !root.isGameClass(c)) continue;
            out.push({ address: t.address ?? "", class: c, title: t.title ?? "" });
        }
        return out;
    }
    readonly property bool inSession: sessions.length > 0

    // A trailing * covers the classes Steam hands its games: one entry,
    // "steam_app*", covers every one of them without listing the ids.
    function isGameClass(cls: string): bool {
        const c = String(cls ?? "").toLowerCase();
        if (c === "")
            return false;
        return (Config.gameAutoList ?? []).some(entry => {
            const p = String(entry ?? "").toLowerCase();
            if (p === c) return true;
            return p.endsWith("*") && c.startsWith(p.slice(0, -1));
        });
    }

    function statusLine(): string {
        if (gamemode > 0)
            return "gamemode is boosting " + gamemode + " client"
                + (gamemode === 1 ? "" : "s");
        if (gamemode === 0) return "gamemoded running, nothing to boost";
        if (hasGamemode) return "gamemoded is not running";
        return "gamemoded is not installed";
    }

    // ── Probe ─────────────────────────────────────────────────────────
    NProcess {
        id: probe
        quiet: true
        running: true
        command: ["sh", "-c",
            'for b in gamemoded mangohud amdgpu_top sensors fancontrol steam; do '
            + 'command -v "$b" >/dev/null 2>&1 && printf "%s\\n" "$b"; done']
        stdout: StdioCollector {
            onStreamFinished: {
                const tools = {};
                for (const line of text.split("\n"))
                    if (line.trim() !== "")
                        tools[line.trim()] = true;
                root.tools = tools;
                root.ready = true;
            }
        }
    }

    NProcess { id: reader; quiet: true }

    function refresh(): void {
        if (root.probing)
            return;
        root.probing = true;
        reader.command = ["python3", Quickshell.shellPath("../../scripts/hub.py"), "hw"];
        reader.running = true;
    }

    // Only while something can show it. Two seconds is as fast as the
    // readings move, and it is cheaper than a widget polling at its own
    // pace while nothing is on screen.
    readonly property bool live: GlobalState.gameBarOpen || GlobalState.settingsOpen

    Timer {
        interval: 2000
        running: root.live
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: root.refresh()
}
