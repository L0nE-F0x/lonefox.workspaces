// Geometry and dispatch helpers for the workspace hover preview.
// Dependency-free so the same file can be required from Node tests.
//
// Window `at`/`size` and monitor x/y are in Hyprland's logical layout.
// Monitor width/height are physical pixels, so the frame divides by scale.

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : 0
}

function axis(v, i) {
  if (v == null) return 0
  if (typeof v === "number") return i === 0 ? num(v) : 0
  if (v.length !== undefined) return num(v[i])
  if (typeof v === "object") return num(v[i] !== undefined ? v[i] : v[String(i)])
  return 0
}

function frameForMonitor(mon) {
  if (!mon) return { x: 0, y: 0, w: 0, h: 0 }
  var scale = num(mon.scale)
  if (scale < 0.1) scale = 1
  var w = num(mon.width) / scale
  var h = num(mon.height) / scale
  if (w < 1 || h < 1) return { x: 0, y: 0, w: 0, h: 0 }
  return { x: num(mon.x), y: num(mon.y), w: w, h: h }
}

// Map one toplevel onto a stage that has the monitor's aspect.
// Fullscreen windows cover the stage. Hidden or unmapped windows are skipped.
// z is higher for the more recently focused window (lower focusHistoryID).
function placeWindow(ipc, frame, stageW, stageH) {
  if (!ipc || !frame || frame.w <= 1 || frame.h <= 1) return null
  if (ipc.mapped === false || ipc.hidden === true) return null
  var stageWidth = num(stageW)
  var stageHeight = num(stageH)
  if (stageWidth < 2 || stageHeight < 2) return null

  var fullscreen = num(ipc.fullscreen) > 0 || num(ipc.fullscreenClient) > 0
  var x
  var y
  var w
  var h
  if (fullscreen) {
    x = 0
    y = 0
    w = stageWidth
    h = stageHeight
  } else {
    var sx = stageWidth / frame.w
    var sy = stageHeight / frame.h
    x = (axis(ipc.at, 0) - frame.x) * sx
    y = (axis(ipc.at, 1) - frame.y) * sy
    w = axis(ipc.size, 0) * sx
    h = axis(ipc.size, 1) * sy
  }
  if (!(w >= 2) || !(h >= 2)) return null
  return { x: x, y: y, w: w, h: h, z: 1000 - num(ipc.focusHistoryID) }
}

function ensure0x(address) {
  var value = String(address == null ? "" : address).trim()
  if (value.length === 0) return ""
  return value.indexOf("0x") === 0 ? value : "0x" + value
}

function isValidAddress(address) {
  return /^0x[0-9a-fA-F]+$/.test(ensure0x(address))
}

function focusWindowDispatch(address) {
  var addr = ensure0x(address)
  if (!isValidAddress(addr)) return ""
  return "hl.dsp.focus({ window = hl.get_window('address:" + addr + "') })"
}

function focusWorkspaceDispatch(workspaceId) {
  var id = Number(workspaceId)
  if (!isFinite(id) || id <= 0 || id !== Math.floor(id)) return ""
  return "hl.dsp.focus({ workspace = tostring(" + id + ") })"
}

if (typeof module !== "undefined") {
  module.exports = {
    frameForMonitor: frameForMonitor,
    placeWindow: placeWindow,
    ensure0x: ensure0x,
    isValidAddress: isValidAddress,
    focusWindowDispatch: focusWindowDispatch,
    focusWorkspaceDispatch: focusWorkspaceDispatch
  }
}
