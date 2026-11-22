import QtQuick
import QtQuick.Layouts
import ".."
import "../.."
import "../../services"

ColumnLayout {
    anchors.fill: parent
    spacing: Theme.px(7)

    // Same three rows the resources widget shows, from the hub's own
    // pass: the game canvas is the one place a session's readings are
    // wanted at the moment they move.
    Stat { label: "CPU"; icon: "󰻠"; value: Sys.cpu; temp: Hub.cpuTemp }
    Stat { label: "RAM"; icon: "󰍛"; value: Sys.ram }
    Stat {
        label: "GPU"
        icon: "󰢮"
        visible: Hub.hasGpu
        value: Hub.gpus[0]?.busy ?? -1
        temp: Hub.gpuTemp
    }
    Stat {
        label: "VRAM"
        icon: "󰢮"
        visible: Hub.hasGpu && (Hub.gpus[0]?.vramUsed ?? -1) >= 0
        value: Hub.vramTotal > 0 ? Hub.gpus[0].vramUsed / Hub.gpus[0].vramTotal : 0
    }
    Item { Layout.fillHeight: true }
}
