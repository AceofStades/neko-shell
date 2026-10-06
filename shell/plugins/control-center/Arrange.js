// Where displays sit next to each other, in Hyprland's layout pixels (the
// mode divided by the scale, turned on its side for 90 and 270 degrees)

// The displays that take a place of their own: on, and not mirroring another
function rects(displays) {
  var list = []
  for (var i = 0; i < (displays || []).length; i++) {
    var d = displays[i]
    if (!d.enabled || (d.mirrorOf && d.mirrorOf !== "none")) continue
    var w = Math.round(d.width / d.scale)
    var h = Math.round(d.height / d.scale)
    var sideways = d.transform % 2 === 1
    list.push({ name: d.name, x: d.x, y: d.y, width: sideways ? h : w, height: sideways ? w : h })
  }
  return list
}

// How far apart two ranges are; negative is how much they overlap
function gap(a0, a1, b0, b1) {
  return Math.max(b0 - a1, a0 - b1)
}

function overlaps(a, b) {
  return gap(a.x, a.x + a.width, b.x, b.x + b.width) < 0 && gap(a.y, a.y + a.height, b.y, b.y + b.height) < 0
}

// Sharing a stretch of edge, so the pointer can cross from one to the other
function touches(a, b) {
  var gx = gap(a.x, a.x + a.width, b.x, b.x + b.width)
  var gy = gap(a.y, a.y + a.height, b.y, b.y + b.height)
  return (gx === 0 && gy < 0) || (gy === 0 && gx < 0)
}

// The nearest x and y within reach of r's edges and center meeting another
// display's edges and center. Returns { x, y, guidesX, guidesY }, the guides
// being the lines where they meet.
function snap(r, others, reach) {
  function best(start, size, lines) {
    var found = { offset: 0, distance: reach + 1, line: null }
    var points = [start, start + size / 2, start + size]
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < points.length; j++) {
        // Centers only meet centers; edges meet edges
        if ((j === 1) !== lines[i].center) continue
        var distance = Math.abs(lines[i].at - points[j])
        if (distance < found.distance) found = { offset: lines[i].at - points[j], distance: distance, line: lines[i].at }
      }
    }
    return found
  }
  var xs = [], ys = []
  for (var i = 0; i < others.length; i++) {
    var o = others[i]
    xs.push({ at: o.x, center: false }, { at: o.x + o.width, center: false }, { at: o.x + o.width / 2, center: true })
    ys.push({ at: o.y, center: false }, { at: o.y + o.height, center: false }, { at: o.y + o.height / 2, center: true })
  }
  var bx = best(r.x, r.width, xs)
  var by = best(r.y, r.height, ys)
  return {
    x: Math.round(r.x + bx.offset),
    y: Math.round(r.y + by.offset),
    guidesX: bx.line === null ? [] : [bx.line],
    guidesY: by.line === null ? [] : [by.line]
  }
}

// Push r out of every display it overlaps, the shortest way each time
function separate(r, others) {
  var out = { name: r.name, x: r.x, y: r.y, width: r.width, height: r.height }
  for (var round = 0; round < 8; round++) {
    var hit = null
    for (var i = 0; i < others.length; i++) if (overlaps(out, others[i])) { hit = others[i]; break }
    if (!hit) return out
    var moves = [
      { x: hit.x - out.width, y: out.y },
      { x: hit.x + hit.width, y: out.y },
      { x: out.x, y: hit.y - out.height },
      { x: out.x, y: hit.y + hit.height }
    ]
    moves.sort(function(a, b) {
      return Math.abs(a.x - out.x) + Math.abs(a.y - out.y) - Math.abs(b.x - out.x) - Math.abs(b.y - out.y)
    })
    out.x = moves[0].x
    out.y = moves[0].y
  }
  // Still in the way after all that: the right of everything is always free
  var right = 0
  for (var j = 0; j < others.length; j++) right = Math.max(right, others[j].x + others[j].width)
  out.x = right
  out.y = others.length > 0 ? others[0].y : out.y
  return out
}

// Move r against the nearest display when it touches none, sharing at least
// a quarter of the shorter edge
function attach(r, others) {
  var out = { name: r.name, x: r.x, y: r.y, width: r.width, height: r.height }
  if (others.length === 0) return out
  for (var i = 0; i < others.length; i++) if (touches(out, others[i])) return out

  var nearest = null, nearestDistance = Infinity
  for (var j = 0; j < others.length; j++) {
    var o = others[j]
    var distance = Math.max(0, gap(out.x, out.x + out.width, o.x, o.x + o.width))
      + Math.max(0, gap(out.y, out.y + out.height, o.y, o.y + o.height))
    if (distance < nearestDistance) { nearest = o; nearestDistance = distance }
  }
  var gx = gap(out.x, out.x + out.width, nearest.x, nearest.x + nearest.width)
  var gy = gap(out.y, out.y + out.height, nearest.y, nearest.y + nearest.height)
  if (gx >= gy) {
    out.x = out.x + out.width / 2 < nearest.x + nearest.width / 2 ? nearest.x - out.width : nearest.x + nearest.width
    var shareY = Math.round(Math.min(out.height, nearest.height) / 4)
    if (gy > -shareY) out.y = out.y < nearest.y ? nearest.y - out.height + shareY : nearest.y + nearest.height - shareY
  } else {
    out.y = out.y + out.height / 2 < nearest.y + nearest.height / 2 ? nearest.y - out.height : nearest.y + nearest.height
    var shareX = Math.round(Math.min(out.width, nearest.width) / 4)
    if (gx > -shareX) out.x = out.x < nearest.x ? nearest.x - out.width + shareX : nearest.x + nearest.width - shareX
  }
  return out
}

// Every display after `name` is dropped at x, y: out of the others' way,
// touching one of them, and the whole layout starting at 0, 0
function drop(list, name, x, y) {
  var moved = null, others = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].name === name) moved = { name: name, x: Math.round(x), y: Math.round(y), width: list[i].width, height: list[i].height }
    else others.push(list[i])
  }
  if (!moved) return list
  moved = separate(attach(separate(moved, others), others), others)

  var all = others.concat([moved])
  var minX = Infinity, minY = Infinity
  for (var j = 0; j < all.length; j++) {
    minX = Math.min(minX, all[j].x)
    minY = Math.min(minY, all[j].y)
  }
  return all.map(function(r) { return { name: r.name, x: r.x - minX, y: r.y - minY, width: r.width, height: r.height } })
}

// Layout pixels to view pixels for a view of the given size: the layout fits
// with room around it to drag a display to any side
function fit(list, width, height, padding) {
  if (list.length === 0) return { scale: 1, x: 0, y: 0 }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, roomX = 0, roomY = 0
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    minX = Math.min(minX, r.x)
    minY = Math.min(minY, r.y)
    maxX = Math.max(maxX, r.x + r.width)
    maxY = Math.max(maxY, r.y + r.height)
    roomX = Math.max(roomX, r.width / 2)
    roomY = Math.max(roomY, r.height / 2)
  }
  var scale = Math.min((width - 2 * padding) / (maxX - minX + 2 * roomX), (height - 2 * padding) / (maxY - minY + 2 * roomY))
  return {
    scale: scale,
    x: width / 2 - (minX + maxX) / 2 * scale,
    y: height / 2 - (minY + maxY) / 2 * scale
  }
}

if (typeof module !== "undefined") {
  module.exports = { rects: rects, overlaps: overlaps, touches: touches, snap: snap, separate: separate, attach: attach, drop: drop, fit: fit }
}
