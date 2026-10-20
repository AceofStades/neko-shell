import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What the clock says, and the shapes it can say it in.
//
// The same component backs the settings window's clock tab and the popup
// a right click on the clock opens, so the two can never drift apart. It
// edits three formats: the one the bar's label shows, the one it shows
// when the bar stands on its side, and the one the scroll wheel switches
// to. The presets cover what the clock says now, what the UniBar's clock
// says, and the usual shapes; anything else goes in the custom field.
Item {
  id: root

  // The formats as they are now
  property string format: "dddd HH:mm"
  property string verticalFormat: "HH\n—\nmm"
  property string altFormat: "d MMMM 'W'ww yyyy"

  // The formats on offer: [{ label, format }]
  property var presets: []

  // The bar stands on its side: the stacked format is the one on show
  property bool vertical: false

  property color foreground: NekoColor.foreground
  property color accent: NekoColor.accent
  property string fontFamily: Style.font.family

  // A field has the keyboard: the panel around it keeps its hands off
  readonly property bool editing: customField.input.activeFocus
    || verticalField.input.activeFocus
    || altField.input.activeFocus

  // The format that changed, and what it changed to
  signal applied(string key, string value)

  readonly property color dim: Util.alpha(root.foreground, 0.6)
  readonly property string shownFormat: root.vertical ? root.verticalFormat : root.format

  readonly property var presetOptions: {
    var options = []
    for (var i = 0; i < root.presets.length; i++)
      options.push({ value: root.presets[i].format, label: root.presets[i].label })
    options.push({ value: "custom", label: "Custom…" })
    return options
  }

  implicitHeight: column.implicitHeight

  SystemClock {
    id: clock
    // Only a format that prints seconds needs the clock to tick that often
    precision: Model.clockNeedsSeconds(root.format) || Model.clockNeedsSeconds(root.verticalFormat)
      ? SystemClock.Seconds : SystemClock.Minutes
  }

  // The format as it reads right now. 'ww' is not a Qt token, so the ISO
  // week number is substituted before the format is handed over.
  function previewOf(format) {
    var text = String(format || "")
    if (text === "") return ""
    var date = clock.date
    return Qt.formatDateTime(date, text.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // The preset the format in use matches, or "custom" for one that is not
  // on the list at all
  function presetFor(format) {
    for (var i = 0; i < root.presets.length; i++)
      if (root.presets[i].format === format) return root.presets[i].format
    return "custom"
  }

  function apply(key, value) {
    var text = String(value === undefined || value === null ? "" : value)
    if (text === "") return
    root.applied(key, text)
  }

  // The dropdown is told what is in use rather than bound to it: picking
  // an entry writes the format back, and the format is what the dropdown
  // then shows.
  Component.onCompleted: presetDropdown.value = root.presetFor(root.format)
  onFormatChanged: presetDropdown.value = root.presetFor(root.format)

  Column {
    id: column
    width: root.width
    spacing: Style.space(12)

    // ------------------------------------------------------- The presets
    Column {
      width: parent.width
      spacing: Style.space(6)

      Text {
        text: "Preset"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1
      }

      Dropdown {
        id: presetDropdown
        width: parent.width
        showLabel: false
        foreground: root.foreground
        accent: root.accent
        options: root.presetOptions
        onChanged: function(v) {
          // "Custom" is not a format: it points at the field below
          if (v === "custom") {
            customField.input.forceActiveFocus()
            customField.input.selectAll()
            return
          }
          root.apply("format", v)
        }
      }
    }

    // ------------------------------------------------- What it will look like
    Rectangle {
      width: parent.width
      implicitHeight: previewBox.implicitHeight + Style.space(20)
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, 0.05)

      Column {
        id: previewBox
        x: Style.space(10)
        y: Style.space(10)
        width: parent.width - Style.space(20)
        spacing: Style.space(4)

        Text {
          width: parent.width
          text: root.previewOf(root.shownFormat)
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        Text {
          width: parent.width
          text: root.shownFormat
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ------------------------------------------------------ The formats
    FieldRow {
      id: customField
      label: "Custom format"
      hint: "Any Qt date format, like dddd HH:mm or HH:mm:ss"
      value: root.format
      placeholder: "dddd HH:mm"
      onApplied: function(value) { root.apply("format", value) }
    }

    FieldRow {
      id: verticalField
      label: "Vertical format"
      hint: "One line per \\n. What the clock says when the bar is on the left or the right"
      value: root.verticalFormat
      placeholder: "HH\\n—\\nmm"
      escapes: true
      onApplied: function(value) { root.apply("verticalFormat", value) }
    }

    FieldRow {
      id: altField
      label: "Second format"
      hint: "What the scroll wheel switches the clock to"
      value: root.altFormat
      placeholder: "d MMMM 'W'ww yyyy"
      onApplied: function(value) { root.apply("formatAlt", value) }
    }
  }

  // A labeled field with an Apply button: the format as it stands, and the
  // way to change it.
  //
  // A format that spans lines cannot be shown in a one-line field, so
  // `escapes` writes the line breaks as \n and reads them back as such.
  component FieldRow: Column {
    id: field
    property string label: ""
    property string hint: ""
    property string value: ""
    property string placeholder: ""
    property bool escapes: false
    // The field itself, so the chooser can put the cursor in it
    property alias input: fieldInput
    signal applied(string value)

    function shown(value) {
      var text = String(value === undefined || value === null ? "" : value)
      return field.escapes ? text.replace(/\n/g, "\\n") : text
    }

    function written(text) {
      var value = String(text === undefined || text === null ? "" : text)
      return field.escapes ? value.replace(/\\n/g, "\n") : value
    }

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)

    Text {
      text: field.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.weight: Font.DemiBold
      font.capitalization: Font.AllUppercase
      font.letterSpacing: 1
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: fieldInput
        width: Math.max(Style.space(80), parent.width - applyButton.width - Style.space(6))
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        placeholderText: field.placeholder
        onAccepted: field.applied(field.written(fieldInput.text))
      }

      Button {
        id: applyButton
        text: "Apply"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        enabled: fieldInput.text.trim() !== "" && fieldInput.text !== field.shown(field.value)
        onClicked: field.applied(field.written(fieldInput.text))
      }
    }

    Text {
      visible: field.hint !== ""
      width: parent.width
      text: field.hint
      wrapMode: Text.Wrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Component.onCompleted: fieldInput.text = field.shown(field.value)
    onValueChanged: if (!fieldInput.activeFocus) fieldInput.text = field.shown(field.value)
  }
}
