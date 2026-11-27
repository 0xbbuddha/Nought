pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import ".."

// The shortcuts Settings lets you rebind: the panel toggles - opening a
// panel, not managing a window - that are simple `ipc(target, action)`
// dispatches in hypr/hyprland/keybinds.lua. Window management and the
// zoom binds stay out: some of those are anonymous Lua functions or
// option tables, neither of which round-trips through a generated file
// the way a plain ipc call does.
//
// Applied the way the display manager and WindowLayout.qml write
// Hyprland state: `hyprctl eval` for the running compositor, and a
// small Lua file hypr/hyprland.lua loads right after the stock
// keybinds, for next boot. `hyprctl keyword` answers "can't work with
// non-legacy parsers" against this Lua config, same as it does there.
Singleton {
    id: root

    readonly property var rebindable: [
        { id: "launcher",        label: "Essential Search",
          mod: "SUPER", key: "R", ipcTarget: "launcher", ipcAction: "toggle" },
        { id: "clipboard",       label: "Clipboard",
          mod: "SUPER", key: "V", ipcTarget: "clipboard", ipcAction: "toggle" },
        { id: "bar",             label: "Control centre",
          mod: "SUPER", key: "N", ipcTarget: "bar", ipcAction: "toggle" },
        { id: "notifications",   label: "Notifications",
          mod: "SUPER", key: "B", ipcTarget: "notifications", ipcAction: "toggle" },
        { id: "settings",        label: "Settings",
          mod: "SUPER", key: "I", ipcTarget: "settings", ipcAction: "toggle" },
        { id: "essential",       label: "Essential Space",
          mod: "SUPER", key: "A", ipcTarget: "essential", ipcAction: "toggle" },
        { id: "apps",            label: "Essential Apps",
          mod: "SUPER + ALT", key: "A", ipcTarget: "apps", ipcAction: "toggle" },
        { id: "game",            label: "Game bar",
          mod: "SUPER", key: "G", ipcTarget: "game", ipcAction: "toggle" },
        { id: "cheatsheet",      label: "This cheatsheet",
          mod: "SUPER", key: "Slash", ipcTarget: "cheatsheet", ipcAction: "toggle" },
        { id: "wallpaperpicker", label: "Wallpaper picker",
          mod: "SUPER + SHIFT", key: "T", ipcTarget: "wallpaperpicker", ipcAction: "toggle" },
        { id: "wallpapernext",   label: "Next wallpaper",
          mod: "SUPER + ALT", key: "W", ipcTarget: "wallpaper", ipcAction: "next" },
        { id: "displays",        label: "Displays, brightness, night light",
          mod: "SUPER", key: "P", ipcTarget: "displays", ipcAction: "toggle" },
        { id: "nightlight",      label: "Night light on or off",
          mod: "SUPER + ALT", key: "B", ipcTarget: "nightlight", ipcAction: "toggle" },
        { id: "caffeine",        label: "Keep the screen awake",
          mod: "SUPER + ALT", key: "I", ipcTarget: "caffeine", ipcAction: "toggle" },
        { id: "processes",       label: "Processes",
          mod: "CTRL + SHIFT", key: "Escape", ipcTarget: "settings", ipcAction: "processes" },
        { id: "glyphnext",       label: "Next Glyph surface",
          mod: "SUPER + SHIFT", key: "G", ipcTarget: "glyph", ipcAction: "next" },
        { id: "nothinglauncher", label: "Nothing Launcher",
          mod: "SUPER + ALT", key: "L", ipcTarget: "nothing", ipcAction: "toggle" },
        { id: "session",         label: "Session menu",
          mod: "CTRL + ALT", key: "Delete", ipcTarget: "session", ipcAction: "toggle" }
    ]

    function entry(id: string): var {
        return root.rebindable.find(e => e.id === id) ?? null;
    }

    function defaultCombo(e: var): string {
        return e.mod + " + " + e.key;
    }

    // The override if there is one, otherwise the default - what is
    // actually bound right now.
    function comboFor(id: string): string {
        const e = root.entry(id);
        if (!e)
            return "";
        const over = (Config.keybindOverrides ?? {})[id];
        return over || root.defaultCombo(e);
    }

    function setCombo(id: string, combo: string): void {
        const e = root.entry(id);
        if (!e)
            return;
        const map = Object.assign({}, Config.keybindOverrides ?? {});
        if (combo === root.defaultCombo(e))
            delete map[id];
        else
            map[id] = combo;
        Config.keybindOverrides = map;
        Config.save();
        root.apply();
    }

    function resetAll(): void {
        Config.keybindOverrides = {};
        Config.save();
        root.apply();
    }

    // Every entry, not only the overridden ones: a key once rebound
    // away from and then cleared still has to be re-bound to its
    // default, which a line simply missing from this script would not
    // do on its own - hyprctl eval has no notion of "since last time".
    readonly property string overridesLua: {
        const lines = [];
        for (const e of root.rebindable) {
            const def = root.defaultCombo(e);
            const cur = root.comboFor(e.id);
            lines.push(`hl.unbind("${def}")`);
            if (cur !== def)
                lines.push(`hl.unbind("${cur}")`);
            lines.push(`hl.bind("${cur}", ipc("${e.ipcTarget}", "${e.ipcAction}"))`);
        }
        return lines.join("\n");
    }

    readonly property string savePath:
        (Quickshell.env("HOME") ?? "") + "/.config/hypr/keybind-overrides.lua"

    readonly property string saveText:
        "-- Written by the Nothing shell (Settings > Input > Shortcuts).\n"
        + "-- Rewritten whenever a shortcut changes here, so edits are lost.\n"
        + "-- Loaded from hypr/hyprland.lua, right after the stock keybinds.\n\n"
        + root.overridesLua + "\n"

    // hyprctl eval wraps its argument in `return`, so the chunk has to
    // be an expression - same shape WindowLayout.qml uses.
    readonly property string chunk:
        "(function() " + root.overridesLua + " return \"ok\" end)()"

    property string savedText: ""
    readonly property bool saved: root.savedText === root.saveText

    function apply(): void {
        applier.running = false;
        applier.command = ["hyprctl", "eval", root.chunk];
        applier.running = true;
        keeper.setText(root.saveText);
    }

    NProcess { id: applier; label: "keybinds" }

    FileView {
        id: keeper
        path: root.savePath
        // Missing until the first rebind, which is not a fault worth
        // printing.
        printErrors: false
        onLoaded: root.savedText = keeper.text()
        onSaved: root.savedText = keeper.text()
    }

    Timer {
        id: settle
        interval: 120
        onTriggered: root.apply()
    }

    Connections {
        target: Config
        function onKeybindOverridesChanged() { settle.restart(); }
    }

    // On startup Hyprland has already read keybind-overrides.lua, so
    // there is nothing to apply unless the file disagrees with the
    // settings: a config copied from another machine, or the file
    // removed by hand.
    Component.onCompleted: catchUp.start()

    Timer {
        id: catchUp
        interval: 1500
        onTriggered: if (Config.ready && !root.saved) root.apply()
    }
}
