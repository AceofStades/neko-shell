import QtQuick
import qs.Commons
import qs.Ui

// On while neko-record has a take going: a press stops it, else picks what
// to record
BarIndicator {
  id: root

  readonly property bool recording: Island.recordLive

  active: recording
  activeText: "󰻂"
  inactiveText: "󰻂"
  activeTooltipText: "Stop recording"
  inactiveTooltipText: "Screen Recording"

  onPressed: function() {
    if (root.bar) root.bar.run(root.recording ? "neko-record stop" : "neko-record start")
  }
}
