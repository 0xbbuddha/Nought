import QtQuick
import ".."

// Press-to-record keybind field. Click it, press the combo, it reports
// what it saw - not a text field, because what matters is the actual
// key event Hyprland would receive, not whether the combo can be typed
// or spelled correctly by hand.
Item {
    id: root
    property string combo: ""
    property bool recording: false
    signal captured(string combo)

    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight

    // Only the keys this rice's rebindable shortcuts actually use
    // (Keybinds.qml) - letters resolve generically, since Qt's own key
    // codes for A-Z already are the ASCII letters.
    function nameFor(key: int): string {
        if (key >= Qt.Key_A && key <= Qt.Key_Z)
            return String.fromCharCode(key);
        switch (key) {
        case Qt.Key_Slash:  return "Slash";
        case Qt.Key_Escape: return "Escape";
        case Qt.Key_Delete: return "Delete";
        default:             return "";
        }
    }

    readonly property var modifierKeys: [
        Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta,
        Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_AltGr
    ]

    NPillButton {
        id: pill
        text: root.recording ? "Press a combo…" : root.combo
        onActivated: {
            root.recording = true;
            root.forceActiveFocus();
        }
    }

    focus: root.recording
    Keys.onEscapePressed: (event) => {
        if (root.recording) {
            root.recording = false;
            event.accepted = true;
        }
    }
    Keys.onPressed: (event) => {
        if (!root.recording)
            return;
        // A held modifier on its own is not "the key" - wait for a real one.
        if (root.modifierKeys.indexOf(event.key) >= 0)
            return;
        event.accepted = true;
        const name = root.nameFor(event.key);
        root.recording = false;
        if (name === "")
            return;
        const mods = [];
        if (event.modifiers & Qt.MetaModifier) mods.push("SUPER");
        if (event.modifiers & Qt.ControlModifier) mods.push("CTRL");
        if (event.modifiers & Qt.AltModifier) mods.push("ALT");
        if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT");
        // A shortcut with no modifier at all would swallow every plain
        // keystroke typed anywhere, so it is not offered as a result.
        if (mods.length === 0)
            return;
        root.captured(mods.join(" + ") + " + " + name);
    }
}
