import QtQuick
import QtQuick.Layouts
import Quickshell
import ".."
import "../components"
import "../services"

// Shortcut cheatsheet, two columns, with search.
OverlayWindow {
    id: win
    open: GlobalState.cheatsheetOpen
    onCloseRequested: GlobalState.cheatsheetOpen = false
    sheetWidth: Math.min(Theme.px(800), screen.width * 0.85)
    sheetHeight: Math.min(Theme.px(560), screen.height * 0.82)

    property var results: Shortcuts.groups

    // What is actually bound right now, not the shipped default: an
    // item with no id is not one Settings > Input > Shortcuts covers,
    // and shows exactly what it always has.
    function effectiveKeys(item: var): var {
        if (!item.id)
            return item.keys;
        const e = Keybinds.entry(item.id);
        if (!e)
            return item.keys;
        const combo = Keybinds.comboFor(item.id);
        if (combo === Keybinds.defaultCombo(e))
            return item.keys;
        // Hyprland's own names for a couple of keys read differently
        // here than everywhere else in this list already does.
        return combo.split(" + ").map(t => {
            if (t === "Escape") return "Esc";
            if (t === "Slash") return "/";
            if (t === "Delete") return "Del";
            return t;
        });
    }

    onShown: {
        field.text = "";
        win.results = Shortcuts.groups;
        field.forceActiveFocus();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.pad
            spacing: Theme.px(12)

            DisplayText { text: "SHORTCUTS"; size: Theme.px(22) }

            Item { Layout.fillWidth: true }

            NIcon { text: "󰍉"; size: Theme.z.iconM; color: Theme.c.onDim }

            TextInput {
                id: field
                Layout.preferredWidth: Theme.px(180)
                color: Theme.c.on
                font.family: Theme.f.sans
                font.pixelSize: Theme.f.body
                selectByMouse: true
                selectionColor: Theme.c.red
                focus: true

                onTextChanged: win.results = Shortcuts.search(text)
                Keys.onEscapePressed: GlobalState.cheatsheetOpen = false

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.text === ""
                    text: "Filter…"
                    color: Theme.c.onFaint
                    font: field.font
                }
            }

            CircleButton {
                icon: "󰅖"
                size: Theme.px(26)
                onActivated: GlobalState.cheatsheetOpen = false
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.c.outline }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: grid.implicitHeight + Theme.pad * 2
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            GridLayout {
                id: grid
                x: Theme.pad
                y: Theme.pad
                width: parent.width - Theme.pad * 2
                columns: 2
                columnSpacing: Theme.px(16)
                rowSpacing: Theme.px(16)

                Repeater {
                    model: win.results

                    ColumnLayout {
                        id: group
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: Theme.px(6)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.px(8)

                            NIcon {
                                text: group.modelData.icon
                                size: Theme.z.icon
                                color: Theme.c.red
                            }
                            NLabel { text: group.modelData.title; dim: false }
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 1
                                color: Theme.c.outline
                            }
                        }

                        Repeater {
                            model: group.modelData.items

                            RowLayout {
                                id: row
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.px(10)

                                NText {
                                    Layout.fillWidth: true
                                    text: row.modelData.label
                                    color: Theme.c.onDim
                                    elide: Text.ElideRight
                                }

                                Row {
                                    spacing: Theme.px(3)

                                    Repeater {
                                        model: win.effectiveKeys(row.modelData)
                                        KeyCap {
                                            required property string modelData
                                            text: modelData
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        NText {
            Layout.fillWidth: true
            Layout.margins: Theme.pad
            visible: win.results.length === 0
            text: "No matching shortcut."
            color: Theme.c.onDim
            horizontalAlignment: Text.AlignHCenter
        }
    }
}
