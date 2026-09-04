// apex-forge-keep
// Workspace indicators with a rich hover card listing what is running in the
// workspace under the cursor.
//
// Why this is a clone rather than a tooltip string: the shared bar tooltip
// (Bar.qml) renders a single centred Text with textFormat: PlainText, so it
// can hold "Workspace 3" but not an icon + app name + window title list.
// Cloning also means lonefox.bar-polish no longer matches this module name,
// so it stops injecting its own "Workspace N" tooltipText -- leaving
// tooltipText empty here is what keeps the plain bubble from double-showing.
// Its accent hover tint still applies, since that keys off the chip shape.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "lonefox.workspaces"

  // ---------------------------------------------------------------- model --

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  // --------------------------------------------------------- app identity --

  // Quickshell's HyprlandToplevel carries the Wayland handle (appId) and the
  // raw `hyprctl clients` object (class). Neither is guaranteed on every
  // surface -- XWayland windows in particular populate class before appId --
  // so try both before falling back to the title.
  function toplevelAppId(tl) {
    if (!tl) return ""
    var w = tl.wayland
    if (w && w.appId) return String(w.appId)
    var ipc = tl.lastIpcObject
    if (ipc) {
      if (ipc.class) return String(ipc.class)
      if (ipc.initialClass) return String(ipc.initialClass)
    }
    return ""
  }

  function desktopEntryFor(appId) {
    var id = String(appId || "").toLowerCase()
    if (id.length === 0) return null

    var values = DesktopEntries.applications.values || []
    var i, entry, entryId

    // Exact desktop-entry id, e.g. class "com.mitchellh.ghostty".
    for (i = 0; i < values.length; i++) {
      entry = values[i]
      entryId = String((entry && entry.id) || "").toLowerCase().replace(/\.desktop$/, "")
      if (entryId === id) return entry
    }

    // Last reverse-DNS segment, e.g. "org.gnome.Nautilus" -> "nautilus".
    var tail = id.indexOf(".") >= 0 ? id.split(".").pop() : id
    for (i = 0; i < values.length; i++) {
      entry = values[i]
      entryId = String((entry && entry.id) || "").toLowerCase().replace(/\.desktop$/, "")
      if (entryId === tail || entryId.split(".").pop() === tail) return entry
    }

    // Display name, e.g. class "Google-chrome" -> "Google Chrome".
    var spaced = tail.replace(/[-_]+/g, " ")
    for (i = 0; i < values.length; i++) {
      entry = values[i]
      if (String((entry && entry.name) || "").toLowerCase() === spaced) return entry
    }

    return null
  }

  // Omarchy webapps (omarchy-launch-webapp) run as plain Chrome --app
  // windows, so their toplevel is classed "Google-chrome" and the lookups
  // above resolve to the generic browser entry. An --app window has no
  // " - Google Chrome" title suffix; its title carries the site name
  // ("Home / X"), which matches the launcher entry created for the webapp
  // (X.desktop -> Name "X", Icon "x").
  function isBrowserEntry(entry) {
    var id = String((entry && entry.id) || "").toLowerCase()
    return /chrom|brave|edge|vivaldi|opera|helium/.test(id)
  }

  // Match the site name carried in the window title ("Home / X") against
  // desktop entry names (X.desktop has Name "X"). Exact, case-insensitive
  // whole-segment match, so a title word that partially overlaps an app
  // name can't hijack the icon. Only reached for browser app-windows.
  function webappEntryForTitle(tl) {
    var t = tl && tl.title ? String(tl.title) : ""
    if (t.length === 0) return null
    // A regular browser window: title ends with the browser's own name.
    if (/[-–—]\s*(google chrome|chromium|brave|microsoft edge)\s*$/i.test(t)) return null

    // Titles carry the site name in many shapes: "Home / X",
    // "web.whatsapp.com" (app window before the page sets its title), or
    // "(2) Discord | #general". Split on separators and dots, drop a leading
    // unread-count badge, then look for an exact segment-to-entry-name match.
    t = t.replace(/^\(\d+\)\s*/, "")
    var segments = t.split(/\s*[\/|·–—.]\s*/)
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      var name = String((entry && entry.name) || "").toLowerCase()
      if (name.length === 0 || name.length > 24) continue
      for (var j = 0; j < segments.length; j++) {
        if (segments[j].toLowerCase() === name) return entry
      }
    }
    return null
  }

  function resolveEntry(tl) {
    var entry = root.desktopEntryFor(root.toplevelAppId(tl))
    if (root.isBrowserEntry(entry)) {
      var webapp = root.webappEntryForTitle(tl)
      if (webapp) return webapp
    }
    return entry
  }

  function appLabel(tl) {
    var appId = root.toplevelAppId(tl)
    var entry = root.resolveEntry(tl)
    if (entry && entry.name) return String(entry.name)

    if (appId.length === 0) return "Unknown"

    // Steam's XWayland surfaces are classed steam_app_<id>, which has no
    // desktop entry and prettifies to the useless "Steam App 2141910". The
    // window title carries the real game name ("MTGA"), so prefer it.
    if (/^steam_app_[0-9]+$/i.test(appId)) {
      var t = tl && tl.title ? String(tl.title) : ""
      if (t.length > 0) return t
    }

    // Prettify a bare class: drop the reverse-DNS prefix, break separators,
    // title-case the words. "com.mitchellh.ghostty" -> "Ghostty".
    var s = appId
    if (s.split(".").length >= 3) s = s.split(".").pop()
    s = s.replace(/[-_]+/g, " ").trim()
    return s.replace(/\b\w/g, function (c) { return c.toUpperCase() })
  }

  function appIcon(tl) {
    var appId = root.toplevelAppId(tl)
    var entry = root.resolveEntry(tl)

    if (entry && entry.icon) {
      var themed = Quickshell.iconPath(String(entry.icon), true)
      if (themed && themed.length > 0) return themed
    }
    if (appId.length > 0) {
      var direct = Quickshell.iconPath(appId.toLowerCase(), true)
      if (direct && direct.length > 0) return direct
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  // ------------------------------------------------------------- hovering --

  property Item hoverItem: null
  property int hoverId: -1
  property bool cardOpen: false

  // Re-evaluates when the workspace list changes or the cursor moves to a
  // different chip, so the card follows live window open/close.
  readonly property var hoverWorkspace: {
    var values = Hyprland.workspaces.values
    var id = root.hoverId
    if (id < 0) return null
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  readonly property int hoverCount: {
    var ws = root.hoverWorkspace
    return ws && ws.toplevels ? ws.toplevels.values.length : 0
  }

  function noteHover(item, id) {
    if (item && item.tooltipHovered) {
      root.hoverItem = item
      root.hoverId = id
      openDelay.restart()
    } else if (root.hoverItem === item) {
      openDelay.stop()
      root.cardOpen = false
      root.hoverItem = null
      root.hoverId = -1
    }
  }

  // Matches the 400ms the shared bar tooltip uses, so the two feel identical.
  Timer {
    id: openDelay
    interval: 400
    onTriggered: {
      if (root.hoverItem && root.hoverItem.tooltipHovered) root.cardOpen = true
      else root.cardOpen = false
    }
  }

  // A chip destroyed mid-hover (monitor unplugged, workspace list rebuilt)
  // never emits an exit, which would strand the card open. Same guard the bar
  // uses for its own tooltip.
  Timer {
    interval: 100
    running: root.cardOpen
    repeat: true
    onTriggered: {
      if (!root.hoverItem || !root.hoverItem.tooltipHovered || !root.hoverItem.visible) {
        root.cardOpen = false
        root.hoverItem = null
        root.hoverId = -1
      }
    }
  }

  // --------------------------------------------------------------- layout --

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        id: chip
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: root.bar
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }

        // Left empty on purpose -- see the header note. The rich card below
        // replaces the plain bubble entirely.
        tooltipText: ""

        onTooltipHoveredChanged: root.noteHover(chip, chip.modelData)
      }
    }
  }

  // ----------------------------------------------------------- hover card --

  PopupCard {
    id: card

    bar: root.bar
    owner: root
    anchorItem: root.hoverItem
    triggerMode: "hover"
    open: root.cardOpen && root.hoverItem !== null
    padding: Style.space(11)

    readonly property real hInset: card.padding * 2
      + Border.left(card.borderSpec) + Border.right(card.borderSpec)

    contentWidth: card.fittedContentWidth(body.implicitWidth + card.hInset, Style.space(420))
    contentHeight: card.fittedContentHeight(body.implicitHeight)

    ColumnLayout {
      id: body
      spacing: Style.space(9)

      // -- header: accent rule, workspace label, window tally --------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Rectangle {
          Layout.preferredWidth: Math.max(2, Style.space(3))
          Layout.preferredHeight: headerLabel.implicitHeight
          color: Color.accent
        }

        Text {
          id: headerLabel
          text: "WORKSPACE " + (root.hoverId >= 0 ? root.hoverId : "")
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1.2
          font.bold: true
          renderType: Text.NativeRendering
        }

        Item { Layout.fillWidth: true; Layout.preferredHeight: 1 }

        Text {
          text: root.hoverCount === 0 ? "empty"
            : root.hoverCount + (root.hoverCount === 1 ? " window" : " windows")
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
        }
      }

      // -- hairline ---------------------------------------------------------
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        visible: root.hoverCount > 0
        color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)
      }

      // -- one row per window ----------------------------------------------
      Repeater {
        model: root.hoverWorkspace ? root.hoverWorkspace.toplevels : null

        RowLayout {
          id: row
          required property var modelData

          Layout.fillWidth: true
          spacing: Style.space(9)

          readonly property string appLabel: root.appLabel(row.modelData)
          readonly property string winTitle: row.modelData ? String(row.modelData.title || "") : ""

          Image {
            Layout.preferredWidth: Style.font.iconLarge
            Layout.preferredHeight: Style.font.iconLarge
            Layout.alignment: Qt.AlignVCenter
            fillMode: Image.PreserveAspectFit
            // Decode at physical pixels; a logical-size decode leaves PNG
            // icons visibly upscaled on this 1.6-scaled panel.
            sourceSize.width: Style.font.iconLarge * Screen.devicePixelRatio
            sourceSize.height: Style.font.iconLarge * Screen.devicePixelRatio
            source: root.appIcon(row.modelData)
            asynchronous: true
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              Layout.fillWidth: true
              // Bounded here rather than by the card width, so the card can
              // size itself from this layout without a binding loop.
              Layout.maximumWidth: Style.space(300)
              text: row.appLabel
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }

            Text {
              Layout.fillWidth: true
              Layout.maximumWidth: Style.space(300)
              // Steam titles become the label above; don't print them twice.
              visible: text.length > 0 && text !== row.appLabel
              text: row.winTitle
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              renderType: Text.NativeRendering
            }
          }
        }
      }

      // -- empty state ------------------------------------------------------
      Text {
        Layout.fillWidth: true
        visible: root.hoverCount === 0
        text: "Nothing running here"
        color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.italic: true
        renderType: Text.NativeRendering
      }
    }
  }
}
