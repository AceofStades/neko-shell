pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// Whether Super is held down, so the bar can show what Super combinations
// do while it is (the workspaces show their numbers). neko.lua binds the
// press of the key itself to neko:super and its release to
// neko:super-released, both without taking the key from anything else and
// whatever other keys came in between.
Singleton {
  id: root

  property bool held: false

  GlobalShortcut {
    appid: "neko"
    name: "super"
    description: "Super pressed"
    onPressed: root.held = true
    onReleased: root.held = false
  }

  GlobalShortcut {
    appid: "neko"
    name: "super-released"
    description: "Super released"
    onPressed: root.held = false
  }
}
