// The backlight moves along a perceptual curve: 16 steps for the brightness
// keys, each split into 4 fine steps (64 ticks in all), spaced on a gamma 2.5
// power curve so every step looks like the same change. neko-brightness-step
// builds the same curve; keep the two in step.
var ticks = 64
var ticksPerStep = 4
var gamma = 2.5

// Raw backlight values for ticks 0..64, from 1 (never fully dark) to max.
// Each tick is at least one unit above the one before, so none is a no-op.
function curve(max) {
  var values = []
  var previous = 0
  for (var i = 0; i <= ticks; i++) {
    var value = Math.floor(Math.pow(i / ticks, gamma) * (max - 1) + 1 + 0.5)
    if (i > 0 && value <= previous) value = previous + 1
    if (value > max) value = max
    values.push(value)
    previous = value
  }
  return values
}

function rawForTick(tick, max) {
  return curve(max)[Math.max(0, Math.min(ticks, Math.round(tick)))]
}

// The tick closest to a raw backlight value
function tickForRaw(raw, max) {
  var values = curve(max)
  var nearest = 0
  for (var i = 1; i <= ticks; i++) {
    if (Math.abs(values[i] - raw) < Math.abs(values[nearest] - raw)) nearest = i
  }
  return nearest
}

// "8" on a full step, "8.2" two fine steps past it
function tickLabel(tick) {
  var step = Math.floor(tick / ticksPerStep)
  var fine = tick % ticksPerStep
  return fine === 0 ? String(step) : step + "." + fine
}

// Where a brightness key lands from the current raw value: a full step, or a
// fine one with `fine`
// A full step lands on the next whole step that way (8.3 goes up to 9 and
// down to 8); a fine step moves by one. Same as neko-brightness-step.
function brightnessKeyTarget(action, raw, max, fine) {
  var current = tickForRaw(raw, max)
  var tick
  if (fine) tick = current + (action === "raise" ? 1 : -1)
  else if (action === "raise") tick = (Math.floor(current / ticksPerStep) + 1) * ticksPerStep
  else tick = current % ticksPerStep ? Math.floor(current / ticksPerStep) * ticksPerStep : current - ticksPerStep
  return Math.max(0, Math.min(ticks, tick))
}

if (typeof module !== "undefined") {
  module.exports = {
    ticks: ticks,
    ticksPerStep: ticksPerStep,
    curve: curve,
    rawForTick: rawForTick,
    tickForRaw: tickForRaw,
    tickLabel: tickLabel,
    brightnessKeyTarget: brightnessKeyTarget
  }
}
