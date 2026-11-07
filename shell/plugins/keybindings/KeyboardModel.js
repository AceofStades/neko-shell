.pragma library

// The keyboard the viewer draws, a desktop layout in key units: each key its
// label, its width, and the names Hyprland's bindings use for it (lowercase).
// A null is a gap. The arrows and the keys above them sit apart on the right.

function k(label, names, width) {
  return { label: label, names: names || [String(label).toLowerCase()], width: width || 1 }
}


var MAIN = [
  [k("Esc", ["escape"]), { gap: 1 }, k("F1"), k("F2"), k("F3"), k("F4"), { gap: 0.5 }, k("F5"), k("F6"), k("F7"), k("F8"), { gap: 0.5 }, k("F9"), k("F10"), k("F11"), k("F12")],
  [k("`", ["grave"]), k("1"), k("2"), k("3"), k("4"), k("5"), k("6"), k("7"), k("8"), k("9"), k("0"), k("-", ["minus"]), k("=", ["equal"]), k("⌫", ["backspace"], 2)],
  [k("Tab", ["tab"], 1.5), k("Q"), k("W"), k("E"), k("R"), k("T"), k("Y"), k("U"), k("I"), k("O"), k("P"), k("[", ["bracketleft"]), k("]", ["bracketright"]), k("\\", ["backslash"], 1.5)],
  [k("Caps", ["caps_lock"], 1.75), k("A"), k("S"), k("D"), k("F"), k("G"), k("H"), k("J"), k("K"), k("L"), k(";", ["semicolon"]), k("'", ["apostrophe"]), k("Enter", ["return"], 2.25)],
  [k("Shift", ["shift"], 2.25), k("Z"), k("X"), k("C"), k("V"), k("B"), k("N"), k("M"), k(",", ["comma"]), k(".", ["period"]), k("/", ["slash"]), k("Shift", ["shift"], 2.75)],
  [k("Ctrl", ["ctrl"], 1.25), k("Super", ["super"], 1.25), k("Alt", ["alt"], 1.25), k("", ["space"], 6.25), k("Alt", ["alt"], 1.25), k("Super", ["super"], 1.25), k("Menu", ["menu"], 1.25), k("Ctrl", ["ctrl"], 1.25)]
]

var SIDE = [
  [k("Prt", ["print"]), k("Scr", ["scroll_lock"]), k("Pse", ["pause"])],
  [k("Ins", ["insert"]), k("Home", ["home"]), k("PgUp", ["prior", "page_up"])],
  [k("Del", ["delete"]), k("End", ["end"]), k("PgDn", ["next", "page_down"])],
  [],
  [{ gap: 1 }, k("↑", ["up"]), { gap: 1 }],
  [k("←", ["left"]), k("↓", ["down"]), k("→", ["right"])]
]

var MODIFIERS = ["SUPER", "CTRL", "ALT", "SHIFT"]
var MASKS = { SHIFT: 1, CTRL: 4, ALT: 8, SUPER: 64 }

// The modifiers a binding's mask holds, in the order they're written
function modsOf(mask) {
  return MODIFIERS.filter(function(mod) { return (mask & MASKS[mod]) !== 0 })
}

function maskOf(mods) {
  return mods.reduce(function(mask, mod) { return mask | MASKS[mod] }, 0)
}

// What a binding's key is called on screen
function keyLabel(key) {
  var names = {
    "return": "Enter", "space": "Space", "slash": "/", "period": ".", "comma": ",", "minus": "-", "equal": "=",
    "bracketleft": "[", "bracketright": "]", "escape": "Esc", "delete": "Del", "print": "Print", "tab": "Tab",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "mouse:272": "Left click", "mouse:273": "Right click", "mouse:274": "Middle click", "mouse_down": "Scroll down", "mouse_up": "Scroll up"
  }
  var lower = String(key).toLowerCase()
  if (names[lower]) return names[lower]
  if (lower.indexOf("switch:") === 0) return key.split(":").slice(2).join(":") + (lower.indexOf(":on:") > 0 ? " closed" : " opened")
  return String(key).replace(/^XF86/, "").replace(/([a-z])([A-Z])/g, "$1 $2")
}

function combo(binding) {
  return modsOf(binding.modmask).concat([keyLabel(binding.key)]).join(" + ")
}

// What a binding does: its description, else the action's own name
function action(binding) {
  if (binding.description) return binding.description
  var name = /\(([^)]*)\)/.exec(String(binding.dispatcher || ""))
  name = name ? name[1] : String(binding.dispatcher || "")
  return name.replace(/_/g, " ").replace(/^./, function(c) { return c.toUpperCase() })
}

// The main map's bindings, one per keys-and-action, sorted by modifier then key
function clean(raw) {
  var seen = ({})
  var out = []
  ;(raw || []).forEach(function(b) {
    if (b.submap) return
    var entry = { modmask: b.modmask || 0, key: String(b.key || ""), description: String(b.description || ""), dispatcher: String(b.dispatcher || ""), mouse: !!b.mouse }
    var id = entry.modmask + "|" + entry.key.toLowerCase()
    if (seen[id]) return
    seen[id] = true
    out.push(entry)
  })
  out.sort(function(a, b) {
    return a.modmask - b.modmask || a.key.toLowerCase().localeCompare(b.key.toLowerCase())
  })
  return out
}

// The bindings shown: those with exactly the modifiers held (all of them when
// none are), on the key looked at if there is one, matching the search
function shown(bindings, mods, key, query) {
  var mask = maskOf(mods)
  var needle = String(query || "").toLowerCase().trim()
  return bindings.filter(function(b) {
    if (mods.length > 0 && b.modmask !== mask) return false
    if (key && b.key.toLowerCase() !== key) return false
    if (!needle) return true
    return (action(b) + " " + combo(b)).toLowerCase().indexOf(needle) >= 0
  })
}

// Each key name with a binding under the modifiers held (any, when none are)
function boundKeys(bindings, mods) {
  var mask = maskOf(mods)
  var keys = ({})
  bindings.forEach(function(b) {
    if (mods.length > 0 && b.modmask !== mask) return
    keys[b.key.toLowerCase()] = true
  })
  return keys
}

// Qt's key codes for the modifiers, to light them as they're held
function modifierForKey(code, Qt) {
  if (code === Qt.Key_Super_L || code === Qt.Key_Super_R || code === Qt.Key_Meta) return "SUPER"
  if (code === Qt.Key_Control) return "CTRL"
  if (code === Qt.Key_Alt || code === Qt.Key_AltGr) return "ALT"
  if (code === Qt.Key_Shift) return "SHIFT"
  return ""
}
