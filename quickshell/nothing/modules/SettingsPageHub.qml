import QtQuick
import QtQuick.Layouts
import ".."
import "../components"
import "../services"

// Hub: the gaming canvas's readouts, the fans, and the auto game mode.
//
// The page only exists to put a face on what Game mode already does, and
// to say honestly what a machine has. Nothing here asks for root except
// the fan curve, which is the one thing in the rice that touches a
// register, and that dialogue names itself.
SettingsPage {
    id: page

    Component.onCompleted: Hub.refresh()

    SettingsSection {
        title: "Gaming hub"

        SettingRow {
            key: "hubStatus"
            label: "Session"
            hint: Hub.sessions.length > 0
                ? Hub.sessions.map(s => s.class).join(", ")
                : "No game running"
        }

        // Sessions are the watch list's windows, live. The list is empty
        // when the page opens on a machine that is not gaming, which is
        // what it says rather than an empty box.
        Repeater {
            model: Hub.sessions
            delegate: SettingRow {
                required property var modelData
                label: modelData.class
                hint: modelData.title
            }
        }

        SettingRow {
            key: "hubTools"
            label: "Tools"
            hint: {
                const on = [];
                if (Hub.hasMangohud) on.push("MangoHud");
                if (Hub.hasGamemode) on.push("gamemoded");
                if (Hub.hasAmdgpuTop) on.push("amdgpu_top");
                return on.length ? on.join(", ") : "none of them installed";
            }
        }

        SettingRow {
            key: "gameMode"
            label: "Performance mode"
            hint: Hub.statusLine()
            DotSwitch {
                checked: Config.gameMode
                onToggled: Game.toggle()
            }
        }

        SettingRow {
            key: "gameFpsLimit"
            visible: Hub.hasMangohud
            label: "FPS limit"
            hint: Config.gameFpsLimit > 0
                ? "capped at " + Config.gameFpsLimit + " fps"
                : "uncapped"
        }
    }

    SettingsSection {
        title: "Temperatures"

        SettingRow {
            key: "hubCpu"
            label: "CPU"
            hint: Hub.cpuTemp > 0 ? Hub.cpuTemp.toFixed(1) + " °C"
                                  : "no sensor the kernel exposes"
        }

        SettingRow {
            key: "hubGpu"
            // visible guards the row's own rendering, not the other
            // bindings on it: Hub.gpus can still be empty the instant
            // hasGpu flips, so every read here goes through ?? too.
            visible: Hub.hasGpu
            label: Hub.gpus[0]?.name ?? ""
            hint: (Hub.gpus[0]?.busy ?? -1) >= 0
                ? Hub.gpus[0].busy + "% · " + Hub.gpus[0].vramUsed + " / "
                  + Hub.gpus[0].vramTotal + " MB"
                : "no counter the driver exposes"
        }

        // The raw table: one row per sensor the kernel exposes, whatever
        // its name. A laptop with three "acpitz" entries shows three.
        Repeater {
            model: Hub.temps
            delegate: SettingRow {
                required property var modelData
                label: modelData.name
                hint: modelData.c.toFixed(1) + " °C"
            }
        }
    }

    SettingsSection {
        title: "Fans"

        SettingRow {
            key: "fanEnabled"
            label: "Fan control"
            hint: !Fans.ready ? "reading the machine…"
                : !Hub.hasFan ? "no fan the kernel exposes"
                : (Fans.count + " fan" + (Fans.count === 1 ? "" : "s"))
            DotSwitch {
                checked: Config.fanEnabled
                onToggled: (v) => {
                    Config.fanEnabled = v;
                    Config.save();
                    if (!v) Fans.release();
                }
            }
        }

        SettingRow {
            key: "fanApply"
            visible: Config.fanEnabled
            label: "Apply the curve"
            hint: Fans.fault !== "" ? Fans.fault
                : (Fans.anyDrivable ? "fancontrol drives the fan from the curve below"
                                    : "the board's own curve owns every fan here")
            DotSwitch {
                checked: Config.fanApply
                enabled: Hub.hasFancontrol && Fans.anyDrivable
                onToggled: (v) => {
                    Config.fanApply = v;
                    Config.save();
                    if (v) Fans.apply();
                    else Fans.release();
                }
            }
        }

        // The curve itself, before it is applied: a line that says what
        // the fan would do at a given temperature, read off the same
        // table the page edits. A preview that only appears after
        // clicking apply is the one kind of surprise a fan curve is
        // allowed to produce.
        SettingRow {
            key: "fanCurve"
            visible: Fans.anyDrivable
            label: "Curve"
            hint: {
                const c = Fans.curve;
                if (c.length === 0) return "empty";
                return c.map(p => p.t + "°=" + p.p).join("  ");
            }
        }

        SettingRow {
            key: "fanPreview"
            visible: Fans.anyDrivable && Hub.cpuTemp > 0
            label: "At " + Hub.cpuTemp.toFixed(0) + " °C"
            hint: "the fan would sit at "
                + Fans.curveAt(Fans.curve, Hub.cpuTemp) + " % of full speed"
        }
    }
}
