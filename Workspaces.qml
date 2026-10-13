// apex-forge-keep
// Workspace indicators with a rich hover card. Resting on a chip lists the
// windows there. Moving onto the card grows it into a live miniature of that
// workspace: windows sit where they sit on the real screen, captured with
// the toplevel-export protocol. Click a window to open it. Move away and
// nothing changes. Hover does not switch workspaces; that would steal focus.
//
// Why this is a clone rather than a tooltip string: the shared bar tooltip
// (Bar.qml) renders a single centred Text with textFormat: PlainText, so it
// can hold "Workspace 3" but not an icon + app name + window title list.
// tooltipText is left empty on purpose so the shared plain bubble never
// shows on top of the hover card.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Preview.js" as Preview

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

  function dispatch(request) {
    if (!request) return
    Hyprland.dispatch(request)
  }

  function close() { root.dismissCard() }

  function focusWorkspace(id) {
    var request = Preview.focusWorkspaceDispatch(id)
    if (!request) return
    root.dismissCard()
    root.dispatch(request)
  }

  function commitWindow(tl) {
    var request = Preview.focusWindowDispatch(tl ? tl.address : "")
    if (!request) {
      root.focusWorkspace(root.hoverId)
      return
    }
    root.dismissCard()
    root.dispatch(request)
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

  // Native-Wayland Chrome classes an --app window by URL and profile
  // ("chrome-web.whatsapp.com__-Default", "chrome-x.com__-Default") instead of
  // the flat "Google-chrome" that XWayland reported. Those ids match no desktop
  // entry, so desktopEntryFor() returns null, isBrowserEntry(null) is false,
  // and the webapp lookup below was never reached -- tooltips fell back to a
  // prettified class ("Com Default", "Chrome X.Com Default") and the generic
  // application-x-executable icon. Recover the site host from the class: URL
  // path separators are mangled to "_", so the host is everything between the
  // browser prefix and the first underscore. The extension-id form
  // ("chrome-ccbj...-Default") has no underscore and deliberately does not
  // match here -- those already resolve by exact desktop-entry id above.
  function browserAppWindowHost(appId) {
    var m = /^(?:chrome|chromium|brave|msedge|vivaldi|opera|helium)-([^_]+)_/i
              .exec(String(appId || ""))
    return m ? m[1].toLowerCase() : ""
  }

  // Match that host against desktop entry names: "web.whatsapp.com" ->
  // WhatsApp.desktop (Name "WhatsApp"), "x.com" -> X.desktop (Name "X").
  // Tries the full host first, then the second-level label, and only ever takes
  // an exact whole-name match so a short label cannot hijack an unrelated
  // entry. Browser entries are skipped so a host like "mail.google.com" cannot
  // land on Google Chrome itself.
  function webappEntryForHost(host) {
    if (!host || host.length === 0) return null
    var labels = host.split(".")
    var candidates = [host]
    if (labels.length >= 2) candidates.push(labels[labels.length - 2])

    var values = DesktopEntries.applications.values || []
    for (var c = 0; c < candidates.length; c++) {
      var want = candidates[c]
      if (!want || want.length === 0) continue
      for (var i = 0; i < values.length; i++) {
        var entry = values[i]
        if (root.isBrowserEntry(entry)) continue
        var name = String((entry && entry.name) || "").toLowerCase()
        if (name.length > 0 && name === want) return entry
      }
    }
    return null
  }

  function resolveEntry(tl) {
    var appId = root.toplevelAppId(tl)
    var entry = root.desktopEntryFor(appId)

    // XWayland path, unchanged: every Chrome window was classed
    // "Google-chrome", so a browser entry means "identify by title instead".
    if (root.isBrowserEntry(entry)) {
      var webapp = root.webappEntryForTitle(tl)
      if (webapp) return webapp
      return entry
    }

    // Native-Wayland path. Prefer the host carried in the class over the title:
    // the title changes as the user moves between chats ("Chat with Bob"),
    // while the class stays put. Fall back to the title lookup for anything the
    // host cannot resolve.
    if (!entry) {
      var host = root.browserAppWindowHost(appId)
      if (host.length > 0) {
        var byHost = root.webappEntryForHost(host)
        if (byHost) return byHost
        var byTitle = root.webappEntryForTitle(tl)
        if (byTitle) return byTitle
      }
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
  // Set while the pointer is on the card. Returns to the name list when the
  // pointer goes back to the chip or the bridge, and stays put across the
  // brief moment child rows hand hover to the miniature.
  property bool previewLatch: false
  readonly property bool previewing: cardOpen && previewLatch
  property real peekAmount: previewing ? 1 : 0
  property string hoveredAddress: ""
  property string previewHint: ""
  // Child mouse areas can take hover from the card's own handler. Count them
  // so the card stays open while the pointer is on a row or the miniature.
  property int listPointers: 0
  property bool stagePointer: false
  property bool bridgePointer: false
  property bool visualPointer: false

  readonly property bool chipHot: hoverItem !== null && hoverItem.visible
    && hoverItem.tooltipHovered === true
  // The name card is a layer, not an xdg popup: on this Hyprland a popup is
  // drawn above the desktop but never hit-tested, so the pointer cannot
  // enter it. The layer's mask is only the card, plus a short bridge down
  // to the chip.
  readonly property bool cardHot: bridgePointer || visualPointer || listPointers > 0 || stagePointer

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

  // Logical monitor the miniature is a scale model of.
  readonly property var previewFrame: {
    var ws = root.hoverWorkspace
    var mon = (ws && ws.monitor) ? ws.monitor : Hyprland.focusedMonitor
    var frame = Preview.frameForMonitor(mon)
    if (frame.w > 1 && frame.h > 1) return frame
    var screen = preview.screen
    if (screen && screen.width > 1 && screen.height > 1)
      return { x: 0, y: 0, w: screen.width, h: screen.height }
    return { x: 0, y: 0, w: 16, h: 10 }
  }

  readonly property real stageTargetW: {
    var frame = root.previewFrame
    var aspect = frame.h > 1 ? frame.w / frame.h : 1.6
    var screenW = preview.screen ? preview.screen.width : 0
    var screenH = preview.screen ? preview.screen.height : 0
    var maxW = Style.space(860)
    if (screenW > 0) maxW = Math.min(maxW, Math.max(Style.space(280), screenW - Style.space(16)))
    var barH = root.bar ? root.bar.barSize : Style.space(26)
    var chrome = headerRow.implicitHeight + Style.space(9) + root.cardChromeV
    var room = screenH > 0 ? screenH - barH - Style.space(12) : Style.space(640)
    var maxH = Math.min(Style.space(540), Math.max(Style.space(180), room - chrome))
    return Math.max(Style.space(280), Math.round(Math.min(maxW, maxH * aspect)))
  }

  readonly property real stageTargetH: {
    var frame = root.previewFrame
    var aspect = frame.h > 1 ? frame.w / frame.h : 1.6
    return Math.max(Style.space(160), Math.round(root.stageTargetW / aspect))
  }

  // List size is the resting card. Peek amount eases the body up to the
  // monitor-aspect stage. One clock drives size and both fades.
  readonly property real swapW: {
    var fromW = Math.max(1, listCol.implicitWidth)
    return fromW + (root.stageTargetW - fromW) * root.peekAmount
  }
  readonly property real swapH: {
    var fromH = Math.max(1, listCol.implicitHeight)
    return fromH + (root.stageTargetH - fromH) * root.peekAmount
  }
  readonly property real listFade: peekAmount >= 0.45 ? 0 : (1 - peekAmount / 0.45)
  readonly property real stageFade: peekAmount <= 0.2 ? 0 : (peekAmount - 0.2) / 0.8

  readonly property real cardPad: Style.space(11)
  readonly property real cardBorder: Math.max(1, Style.space(2))
  readonly property real cardChromeV: cardPad * 2 + cardBorder * 2
  readonly property real cardChromeH: cardPad * 2 + cardBorder * 2
  // Transparent hit strip between the chip and the card, plus a few pixels
  // of overlap into the bar so the pointer never has to cross a dead gap.
  readonly property real bridge: Math.max(4, Style.gapsOut)
  readonly property real bridgeOverlap: 4
  readonly property real visualW: Math.round(Math.max(1, body.implicitWidth + cardChromeH))
  readonly property real visualH: Math.round(Math.max(1, body.implicitHeight + cardChromeV))

  // Chip rectangle in this screen's coordinates. The bar surface is anchored
  // to an edge, so its window origin is not the screen origin.
  readonly property var chipBox: {
    var item = root.hoverItem
    if (!item) return { x: 0, y: 0, w: 20, h: 26 }
    var win = item.QsWindow ? item.QsWindow.window : null
    var localX = 0
    var localY = 0
    if (win && win.contentItem) {
      var p = win.contentItem.mapFromItem(item, 0, 0)
      if (p) {
        localX = p.x
        localY = p.y
      }
    }
    var ox = 0
    var oy = 0
    var pos = root.bar && root.bar.position ? root.bar.position : "bottom"
    if (win && win.screen) {
      if (pos === "bottom") oy = win.screen.height - win.height
      else if (pos === "right") ox = win.screen.width - win.width
    }
    return { x: ox + localX, y: oy + localY, w: item.width, h: item.height }
  }

  readonly property string barEdge: root.bar && root.bar.position ? root.bar.position : "bottom"

  readonly property real hitX: {
    var box = root.chipBox
    var screenW = preview.screen ? preview.screen.width : 0
    var x = box.x + box.w / 2 - root.visualW / 2
    if (root.barEdge === "left") x = box.x + box.w
    else if (root.barEdge === "right") x = box.x - root.bridge - root.visualW
    if (screenW > 0) x = Math.max(4, Math.min(x, screenW - root.visualW - 4))
    return Math.round(x)
  }

  readonly property real hitY: {
    var box = root.chipBox
    var screenH = preview.screen ? preview.screen.height : 0
    var span = root.visualH + root.bridge + root.bridgeOverlap
    // Pin the edge that faces the bar, so growing the card does not shove
    // the pointer off it. Rounding the anchored edge (not the moving one)
    // keeps that edge still while the size eases.
    var y
    if (root.barEdge === "bottom") y = Math.round(box.y - root.bridge) - root.visualH
    else if (root.barEdge === "top") y = Math.round(box.y + box.h)
    else y = Math.round(box.y + box.h / 2 - (root.visualH + root.bridge) / 2)
    if (screenH > 0) {
      var minY = 4
      var maxY = Math.max(minY, screenH - span - 4)
      y = Math.max(minY, Math.min(y, maxY))
    }
    return y
  }

  readonly property string hintText: {
    if (root.peekAmount > 0.55 && root.previewHint.length > 0) return root.previewHint
    if (root.peekAmount > 0.55)
      return root.hoverCount === 0 ? "click to switch" : "click a window"
    if (root.hoverCount === 0) return "empty"
    return root.hoverCount + (root.hoverCount === 1 ? " window" : " windows")
  }

  Behavior on peekAmount {
    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
  }

  readonly property string wallpaperLink: (Quickshell.env("HOME") || "")
    + "/.local/state/omarchy/current/background"
  property string wallpaperPath: ""
  readonly property string wallpaperUrl: wallpaperPath.length > 0 ? Util.fileUrl(wallpaperPath) : ""

  function noteHover(item, id) {
    if (item && item.tooltipHovered) {
      var switched = root.hoverId !== id
      root.hoverItem = item
      root.hoverId = id
      if (switched) {
        root.hoveredAddress = ""
        root.previewHint = ""
      }
      closeDelay.stop()
      if (!root.cardOpen) openDelay.restart()
    } else if (root.hoverItem === item) {
      openDelay.stop()
      root.considerClose()
    }
  }

  function considerClose() {
    if (root.chipHot || root.cardHot) {
      closeDelay.stop()
      return
    }
    if (root.cardOpen || root.hoverItem !== null) closeDelay.restart()
  }

  function finishClose() {
    if (root.chipHot || root.cardHot) return
    root.dismissCard()
  }

  function dismissCard() {
    openDelay.stop()
    closeDelay.stop()
    root.cardOpen = false
    root.previewLatch = false
    root.hoveredAddress = ""
    root.previewHint = ""
    root.listPointers = 0
    root.stagePointer = false
    root.bridgePointer = false
    root.visualPointer = false
    root.holdBar(false)
    dismissClear.restart()
  }

  function holdBar(open) {
    var bar = root.bar
    if (!bar) return
    if (open) {
      if (bar.requestPopout) bar.requestPopout(root)
    } else if (bar.releasePopout && bar.activePopout === root) {
      bar.releasePopout(root)
    }
  }

  function windowFrame(tl, stageW, stageH) {
    if (!tl) return null
    return Preview.placeWindow(tl.lastIpcObject, root.previewFrame, stageW, stageH)
  }

  function toplevelAt(x, y, stageW, stageH) {
    var ws = root.hoverWorkspace
    var tls = ws && ws.toplevels ? ws.toplevels.values : null
    if (!tls) return null
    var best = null
    var bestZ = -100000
    for (var i = 0; i < tls.length; i++) {
      var geo = root.windowFrame(tls[i], stageW, stageH)
      if (!geo) continue
      if (x < geo.x || y < geo.y || x > geo.x + geo.w || y > geo.y + geo.h) continue
      if (geo.z >= bestZ) {
        bestZ = geo.z
        best = tls[i]
      }
    }
    return best
  }

  function trackStage(x, y, stageW, stageH) {
    var tl = root.toplevelAt(x, y, stageW, stageH)
    if (!tl) {
      root.hoveredAddress = ""
      root.previewHint = ""
      return
    }
    root.hoveredAddress = String(tl.address || "")
    root.previewHint = root.appLabel(tl)
  }

  onCardHotChanged: considerClose()

  function syncPreview() {
    if (!root.cardOpen) {
      root.previewLatch = false
      return
    }
    // Back on the chip, the name list returns. The chip sits outside the
    // card, and a hover handler can miss that leave as the pointer crosses
    // onto the bar, so the chip wins over a stale card hover.
    if (root.chipHot) {
      root.previewLatch = false
      return
    }
    var onCard = root.visualPointer || root.stagePointer || root.listPointers > 0
    if (onCard) root.previewLatch = true
    else if (root.bridgePointer) root.previewLatch = false
  }

  onVisualPointerChanged: syncPreview()
  onStagePointerChanged: syncPreview()
  onListPointersChanged: syncPreview()
  onBridgePointerChanged: syncPreview()
  onChipHotChanged: syncPreview()

  onCardOpenChanged: {
    root.holdBar(cardOpen)
    root.syncPreview()
  }

  onPreviewingChanged: {
    if (!previewing) return
    Hyprland.refreshToplevels()
    if (!wallpaperReadlink.running) wallpaperReadlink.running = true
  }

  // Matches the 400ms the shared bar tooltip uses, so the two feel identical.
  Timer {
    id: openDelay
    interval: 400
    onTriggered: {
      if (root.chipHot) root.cardOpen = true
    }
  }

  // The card sits a few pixels off the bar. Hold it open across that gap,
  // and across a brief slip while the miniature is growing.
  Timer {
    id: closeDelay
    interval: 280
    onTriggered: root.finishClose()
  }

  // Keep the last workspace painted while the card fades, then drop it.
  Timer {
    id: dismissClear
    interval: 180
    onTriggered: {
      if (root.cardOpen || root.chipHot || root.cardHot) return
      root.hoverItem = null
      root.hoverId = -1
    }
  }

  // A chip destroyed mid-hover never emits an exit. Don't restart the grace
  // timer from here or it would never elapse.
  Timer {
    interval: 200
    running: root.cardOpen
    repeat: true
    onTriggered: {
      if (!root.hoverItem || !root.hoverItem.visible) {
        root.dismissCard()
        return
      }
      if (!root.chipHot && !root.cardHot && !closeDelay.running) closeDelay.restart()
    }
  }

  Process {
    id: wallpaperReadlink
    command: ["readlink", "-f", root.wallpaperLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path.length > 0) root.wallpaperPath = path
      }
    }
  }

  Component.onCompleted: wallpaperReadlink.running = true

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
  // Full-screen overlay whose input mask is only the card. An xdg popup
  // cannot be hovered here; a layer can.

  PanelWindow {
    id: preview

    visible: root.hoverItem !== null && (root.cardOpen || shell.opacity > 0.01)
    color: "transparent"
    screen: {
      var item = root.hoverItem
      var win = item && item.QsWindow ? item.QsWindow.window : null
      return win ? win.screen : null
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "lonefox-workspace-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    mask: Region { item: hit }

    Item {
      id: hit
      x: root.hitX
      y: root.hitY
      width: root.visualW
      height: root.visualH + root.bridge + root.bridgeOverlap

      BorderSurface {
        id: shell
        x: 0
        y: (root.barEdge === "top" || root.barEdge === "left") ? root.bridge + root.bridgeOverlap : 0
        width: root.visualW
        height: root.visualH
        color: Color.popups.background
        borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, root.cardBorder)
        radius: Style.cornerRadius
        opacity: root.cardOpen ? 1 : 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        // Stays hovered while the pointer is over a row or a window. A
        // MouseArea would lose the hover to those children and the card
        // would collapse in the middle of opening.
        HoverHandler {
          id: shellHover
          onHoveredChanged: root.visualPointer = hovered
        }

        ColumnLayout {
          id: body
          x: root.cardPad + root.cardBorder
          y: root.cardPad + root.cardBorder
          spacing: Style.space(9)

      // -- header: accent rule, workspace label, window tally --------------
      RowLayout {
        id: headerRow
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
          Layout.maximumWidth: Style.space(240)
          text: root.hintText
          color: (root.peekAmount > 0.55 && root.previewHint.length > 0)
            ? Color.accent
            : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.45)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          renderType: Text.NativeRendering
        }
      }

      Item {
        id: swap
        Layout.preferredWidth: root.swapW
        Layout.preferredHeight: root.swapH
        width: root.swapW
        height: root.swapH
        clip: true

        ColumnLayout {
          id: listCol
          anchors.centerIn: parent
          opacity: root.listFade
          spacing: Style.space(9)

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            visible: root.hoverCount > 0
            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12)
          }

          Repeater {
            model: root.hoverWorkspace ? root.hoverWorkspace.toplevels : null

            Item {
              id: rowWrap
              required property var modelData

              Layout.fillWidth: true
              implicitWidth: row.implicitWidth
              implicitHeight: row.implicitHeight

              Rectangle {
                anchors.fill: parent
                radius: 4
                color: rowMouse.containsMouse
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14)
                  : "transparent"
              }

              RowLayout {
                id: row
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(9)

                readonly property string appLabel: root.appLabel(rowWrap.modelData)
                readonly property string winTitle: rowWrap.modelData ? String(rowWrap.modelData.title || "") : ""

                Image {
                  Layout.preferredWidth: Style.font.iconLarge
                  Layout.preferredHeight: Style.font.iconLarge
                  Layout.alignment: Qt.AlignVCenter
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: Style.font.iconLarge * Screen.devicePixelRatio
                  sourceSize.height: Style.font.iconLarge * Screen.devicePixelRatio
                  source: root.appIcon(rowWrap.modelData)
                  asynchronous: true
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
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

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.peekAmount < 0.35
                cursorShape: Qt.PointingHandCursor
                onEntered: root.listPointers = root.listPointers + 1
                onExited: root.listPointers = Math.max(0, root.listPointers - 1)
                onEnabledChanged: if (!enabled) root.listPointers = 0
                onClicked: root.commitWindow(rowWrap.modelData)
              }
            }
          }

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

        // Monitor-aspect stage. Centered so the resize never stretches windows.
        Rectangle {
          id: stage
          readonly property real aspect: root.previewFrame.h > 1
            ? root.previewFrame.w / root.previewFrame.h : 1.6
          width: Math.min(parent.width, parent.height * aspect)
          height: width / aspect
          anchors.centerIn: parent
          radius: Math.max(4, Style.cornerRadius)
          clip: true
          color: Color.background
          border.width: 1
          border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)
          opacity: root.stageFade
          visible: root.peekAmount > 0.04

          Image {
            anchors.fill: parent
            visible: root.wallpaperUrl.length > 0
            source: root.wallpaperUrl
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
          }

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.18)
          }

          Rectangle {
            visible: root.hoverCount === 0
            anchors.centerIn: parent
            width: emptyLabel.implicitWidth + Style.space(18)
            height: emptyLabel.implicitHeight + Style.space(10)
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.5)

            Text {
              id: emptyLabel
              anchors.centerIn: parent
              text: "Nothing running here"
              color: "white"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.italic: true
              renderType: Text.NativeRendering
            }
          }

          Repeater {
            model: root.hoverWorkspace ? root.hoverWorkspace.toplevels : null

            Rectangle {
              id: win
              required property var modelData
              readonly property var geo: root.windowFrame(win.modelData, stage.width, stage.height)
              readonly property bool hot: root.hoveredAddress !== ""
                && root.hoveredAddress === String(win.modelData ? win.modelData.address || "" : "")

              visible: geo !== null && geo !== undefined
              x: geo ? geo.x : 0
              y: geo ? geo.y : 0
              width: geo ? Math.max(2, geo.w) : 0
              height: geo ? Math.max(2, geo.h) : 0
              z: geo ? geo.z : 0
              radius: 4
              clip: true
              color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.92)
              border.width: hot ? 2 : 1
              border.color: hot
                ? Color.accent
                : Qt.rgba(1, 1, 1, 0.2)

              ScreencopyView {
                id: capture
                anchors.fill: parent
                anchors.margins: 1
                live: win.visible && root.peekAmount > 0.15
                captureSource: (win.modelData && win.modelData.wayland) ? win.modelData.wayland : null
                constraintSize: Qt.size(Math.max(1, width), Math.max(1, height))
              }

              Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - 8, Style.space(160))
                spacing: Style.space(4)
                visible: !capture.hasContent

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.min(Style.font.iconLarge * 1.6, win.height * 0.34)
                  height: width
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  source: root.appIcon(win.modelData)
                  asynchronous: true
                }

                Text {
                  width: parent.width
                  visible: win.height > 48
                  text: root.appLabel(win.modelData)
                  color: "white"
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  renderType: Text.NativeRendering
                }
              }
            }
          }

          MouseArea {
            z: 10000
            anchors.fill: parent
            hoverEnabled: true
            enabled: root.peekAmount > 0.45
            cursorShape: Qt.PointingHandCursor
            // entered() carries no mouse event. mouseX/mouseY are the
            // area's own coordinates and stay valid once the pointer is inside.
            onEnabledChanged: {
              if (!enabled) {
                root.stagePointer = false
                return
              }
              if (containsMouse) {
                root.stagePointer = true
                root.trackStage(mouseX, mouseY, stage.width, stage.height)
              }
            }
            onEntered: {
              root.stagePointer = true
              root.trackStage(mouseX, mouseY, stage.width, stage.height)
            }
            onPositionChanged: {
              root.stagePointer = true
              root.trackStage(mouseX, mouseY, stage.width, stage.height)
            }
            onExited: {
              root.stagePointer = false
              root.hoveredAddress = ""
              root.previewHint = ""
            }
            onClicked: {
              if (root.peekAmount < 0.92) return
              var tl = root.toplevelAt(mouseX, mouseY, stage.width, stage.height)
              if (tl) root.commitWindow(tl)
              else root.focusWorkspace(root.hoverId)
            }
          }
        }
      }
    }
  }

      MouseArea {
        // The side of the card that faces the bar. Crossing it keeps the
        // card open; the miniature starts once the pointer reaches the card.
        x: 0
        y: (root.barEdge === "top" || root.barEdge === "left") ? 0 : root.visualH
        width: parent.width
        height: root.bridge + root.bridgeOverlap
        hoverEnabled: true
        onEntered: root.bridgePointer = true
        onExited: root.bridgePointer = false
      }
    }
  }
}
