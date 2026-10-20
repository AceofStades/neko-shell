// The output volume moves along 64 ticks, sixteen steps of four, like the
// backlight does (see BrightnessModel.js), and every tick is the same change in
// decibels: 0.8 dB. PulseAudio's and PipeWire's volume is already cubic (its
// cube is the amplitude), so equal steps of it are not equal steps of loudness;
// equal decibels are. The step is just over the 0.75 dB the HDA hardware
// mixers move in, so no tick lands on the same hardware step as the one before
// it, however the card rounds.
//
// The top of the scale, tick 64, is 150% of the sink's volume, which reads as
// 100% on the bar: 100% is not loud enough on many outputs, and the sink takes
// up to about 153%. Labels read the sink's own percent, so the top says 150%. Tick 0 is silence. neko-audio-output-volume and MediaModel.js
// build the same scale; keep the three in step.
var ticks = 64
var ticksPerStep = 4
var maxVolume = 1.5
var dbPerTick = 0.8
// The decibels of the top tick, the volume being cubic
var dbTop = 60 * Math.log(maxVolume) / Math.LN10

// The sink's volume (1 being its 100%) for a tick on the slider
function volumeForTick(tick) {
  var t = Math.max(0, Math.min(ticks, Math.round(tick)))
  if (t === 0) return 0
  return Math.pow(10, (dbTop - (ticks - t) * dbPerTick) / 60)
}

// The tick closest to a sink volume, past the top of the scale held at the top
function tickForVolume(volume) {
  var v = Math.min(maxVolume, Number(volume) || 0)
  if (v <= 0) return 0
  var t = ticks - Math.round((dbTop - 60 * Math.log(v) / Math.LN10) / dbPerTick)
  return Math.max(0, Math.min(ticks, t))
}

// What the volume reads as: the sink's own percent, up to 150, as pavucontrol
// shows it
function percentForVolume(volume) {
  return Math.round(100 * Math.max(0, Number(volume) || 0))
}

// Where a key or the wheel lands from a tick: the next whole step that way
// (8.3 goes up to 9 and down to 8), or one fine tick
function stepTick(tick, direction, fine) {
  var next
  if (fine) next = tick + direction
  else if (direction > 0) next = (Math.floor(tick / ticksPerStep) + 1) * ticksPerStep
  else next = tick % ticksPerStep ? Math.floor(tick / ticksPerStep) * ticksPerStep : tick - ticksPerStep
  return Math.max(0, Math.min(ticks, next))
}

// "8" on a full step, "8.2" two fine steps past it
function tickLabel(tick) {
  var step = Math.floor(tick / ticksPerStep)
  var fine = tick % ticksPerStep
  return fine === 0 ? String(step) : step + "." + fine
}

if (typeof module !== "undefined") {
  module.exports = {
    ticks: ticks,
    ticksPerStep: ticksPerStep,
    maxVolume: maxVolume,
    dbPerTick: dbPerTick,
    volumeForTick: volumeForTick,
    tickForVolume: tickForVolume,
    percentForVolume: percentForVolume,
    stepTick: stepTick,
    tickLabel: tickLabel
  }
}
