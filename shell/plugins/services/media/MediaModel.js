function isProxyPlayer(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function hasMetadata(player) {
  return !!(player && (player.trackTitle || player.trackArtist || player.identity || player.desktopEntry))
}

function hasTrackMetadata(player) {
  return !!(player && (player.trackTitle || player.trackArtist || player.trackAlbum || player.trackArtUrl))
}

function playerCanControl(player) {
  return !!(player && (player.canTogglePlaying || player.canPlay || player.canPause || player.canGoNext || player.canGoPrevious))
}

function canHandleAction(player, action) {
  if (!player) return false
  if (action === "next") return !!player.canGoNext
  if (action === "previous") return !!player.canGoPrevious
  if (action === "play") return !!(player.canPlay || player.canTogglePlaying)
  if (action === "pause") return !!(player.canPause || player.canTogglePlaying)
  if (action === "playPause") return !!(player.canTogglePlaying || player.canPlay || player.canPause)
  return false
}

function canCycleSource(player) {
  return !!(player && hasMetadata(player) && (player.isPlaying || player.canPlay))
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function streamLabelKey(label) {
  var key = String(label || "").toLowerCase()
  key = key.replace(/^pipewire alsa \[/, "")
  key = key.replace(/\]$/, "")
  key = key.replace(/^alsa playback \[/, "")
  key = key.replace(/[^a-z0-9]+/g, "")
  return key
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["node.name"]
    || node.name
}

function playerAppLabel(player) {
  if (!player) return ""
  var dbus = String(player.dbusName || "")
  dbus = dbus.replace(/^org\.mpris\.MediaPlayer2\./, "")
  dbus = dbus.replace(/\.instance[0-9]+$/, "")
  return player.desktopEntry || player.identity || dbus
}

function playerHasPlaybackStream(player, playbackStreams) {
  var playerKey = streamLabelKey(playerAppLabel(player))
  if (!playerKey) return false

  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  for (var i = 0; i < streams.length; i++) {
    var streamKey = streamLabelKey(rawStreamLabel(streams[i]))
    if (!streamKey) continue
    if (streamKey === playerKey
        || streamKey.indexOf(playerKey) !== -1
        || playerKey.indexOf(streamKey) !== -1)
      return true
  }

  return false
}

function playerKey(player) {
  if (!player) return ""
  return String(player.dbusName || player.desktopEntry || player.identity || "")
}

function trackSignature(player) {
  if (!player) return ""
  return [
    player.trackTitle || "",
    player.trackArtist || "",
    player.trackAlbum || "",
    player.trackArtUrl || ""
  ].join("\u001f")
}

function trackChanged(previousSignature, player) {
  return trackSignature(player) !== String(previousSignature || "")
}

function labelFor(player) {
  if (!player) return ""
  return player.trackTitle || player.identity || player.desktopEntry || ""
}

function osdMessage(player, fallback) {
  if (!player) return fallback
  var label = labelFor(player)
  if (label && player.trackArtist) return label + " - " + player.trackArtist
  return label || fallback
}

// What a volume key does to the output, by neko-audio-output-volume's rules:
// the volume moves along 64 ticks, sixteen steps of four, each the same 0.8 dB,
// the top 150% of the sink's volume, which reads as 100%. raise and lower land
// on the next whole step that way (8.3 goes up to 9 and down to 8); the fine
// variants move one tick. Each unmutes as it goes; mute-toggle flips mute and
// keeps the volume. `volume` is the sink's volume, 1 being its 100%. `hint` is
// the last tick set and the volume it made, since a card that moves in coarse
// hardware steps reports back something near that, and the next key must not
// read it as the tick before. Same scale as shell/services/VolumeModel.js;
// keep the two in step.
var volumeTicks = 64
var volumeTicksPerStep = 4
var volumeMax = 1.5
var volumeDbPerTick = 0.8
var volumeDbTop = 60 * Math.log(volumeMax) / Math.LN10

function volumeForTick(tick) {
  var t = Math.max(0, Math.min(volumeTicks, Math.round(tick)))
  if (t === 0) return 0
  return Math.pow(10, (volumeDbTop - (volumeTicks - t) * volumeDbPerTick) / 60)
}

function volumeTickFor(volume) {
  var v = Math.min(volumeMax, Number(volume) || 0)
  if (v <= 0) return 0
  var t = volumeTicks - Math.round((volumeDbTop - 60 * Math.log(v) / Math.LN10) / volumeDbPerTick)
  return Math.max(0, Math.min(volumeTicks, t))
}

// What a tick reads as: the sink's own percent, up to 150, as pavucontrol
// shows it
function volumePercentForTick(tick) {
  return Math.round(100 * volumeForTick(tick))
}

function volumeKeyStep(action, volume, muted, hint) {
  // Within a few percent of what was last set, it is what was last set
  var current = hint && hint.volume > 0 && Math.abs(volume - hint.volume) / hint.volume < 0.05 ? hint.tick : volumeTickFor(volume)
  var tick
  if (action === "raise") tick = (Math.floor(current / volumeTicksPerStep) + 1) * volumeTicksPerStep
  else if (action === "lower") tick = current % volumeTicksPerStep ? Math.floor(current / volumeTicksPerStep) * volumeTicksPerStep : current - volumeTicksPerStep
  else if (action === "raise-fine") tick = current + 1
  else if (action === "lower-fine") tick = current - 1
  else if (action === "mute-toggle") return { tick: current, volume: volume, percent: volumePercentForTick(current), muted: !muted }
  else return null
  tick = Math.max(0, Math.min(volumeTicks, tick))
  return { tick: tick, volume: volumeForTick(tick), percent: volumePercentForTick(tick), muted: false }
}

function volumeOsdIcon(percent, muted) {
  return muted || percent === 0 ? "volume-muted" : "volume-high"
}

if (typeof module !== "undefined") {
  module.exports = {
    isProxyPlayer: isProxyPlayer,
    hasMetadata: hasMetadata,
    hasTrackMetadata: hasTrackMetadata,
    playerCanControl: playerCanControl,
    canHandleAction: canHandleAction,
    canCycleSource: canCycleSource,
    nodeProps: nodeProps,
    isPlaybackStream: isPlaybackStream,
    streamLabelKey: streamLabelKey,
    rawStreamLabel: rawStreamLabel,
    playerAppLabel: playerAppLabel,
    playerHasPlaybackStream: playerHasPlaybackStream,
    playerKey: playerKey,
    trackSignature: trackSignature,
    trackChanged: trackChanged,
    labelFor: labelFor,
    osdMessage: osdMessage,
    volumeKeyStep: volumeKeyStep,
    volumeTickFor: volumeTickFor,
    volumeForTick: volumeForTick,
    volumeOsdIcon: volumeOsdIcon
  }
}
