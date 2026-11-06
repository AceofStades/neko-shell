//! `neko-core record`: the screen recorder. gpu-screen-recorder captures; this
//! picks what to record, runs the take, pauses it, and makes the saved file
//! (the countdown and the capture's first frame trimmed, the audio evened out,
//! a thumbnail and a line in the history).
//!
//! Each take runs as a transient unit of its own (neko-record), so a shell
//! restart doesn't end it. Its state is $XDG_RUNTIME_DIR/neko/record.json,
//! which the shell watches; the settings and the history are in
//! ~/.local/state/neko.
//!
//!   status                        the state, the settings and whether the
//!                                 recorder is installed, as JSON
//!   start [--monitor[=NAME]|--window] [--set key=value]...
//!                                 pick an area, a window or a monitor (or take
//!                                 the focused monitor or the active window)
//!                                 and record it
//!   toggle [start's options]      stop a take, or start one
//!   stop [--discard]              save the take, or throw it away
//!   pause|resume|toggle-pause
//!   history [limit]               saved takes, newest first, as JSON
//!   trash <file>                  move a take from the history to the trash
//!   set <key> <value>             change a setting (see SETTINGS); folder
//!                                 takes a directory, webcamDevice a
//!                                 /dev/video* (empty for the first camera)
//!   take <target> <kind> <label> [--set key=value]...
//!                                 the take itself, which the unit runs

use std::fs::{self, File, OpenOptions};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::Local;
use serde_json::{Map, Value, json};

const UNIT: &str = "neko-record";
const RECORDER: &str = "gpu-screen-recorder";
const MAX_HISTORY: usize = 200;
/// How long the recorder gets to produce its file before the take is given up
const START_LIMIT: Duration = Duration::from_secs(15);

/// Each setting, its default and what it may be
const SETTINGS: &[(&str, &str, &[&str])] = &[
    ("desktopAudio", "on", &["on", "off"]),
    ("microphone", "off", &["on", "off"]),
    ("noiseReduction", "off", &["on", "off"]),
    ("cursor", "on", &["on", "off"]),
    ("webcam", "off", &["on", "off"]),
    ("webcamSize", "medium", &["small", "medium", "large"]),
    ("fps", "60", &["30", "60", "120"]),
    ("quality", "very_high", &["medium", "high", "very_high", "ultra"]),
    ("codec", "auto", &["auto", "h264", "hevc", "av1"]),
    ("container", "mp4", &["mp4", "mkv"]),
    ("countdown", "3", &["0", "3", "5", "10"]),
];

// ------------------------------------------------------------------ files

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var(name).ok().filter(|dir| !dir.is_empty()).map(PathBuf::from)
}

fn state_dir() -> PathBuf {
    env_dir("XDG_STATE_HOME").unwrap_or_else(|| home().join(".local/state")).join("neko")
}

/// The live state: the runtime directory is the user's own (0700) and goes
/// with the session, as a take does
fn runtime_dir() -> PathBuf {
    env_dir("XDG_RUNTIME_DIR").map(|dir| dir.join("neko")).unwrap_or_else(state_dir)
}

fn thumb_dir() -> PathBuf {
    env_dir("XDG_CACHE_HOME").unwrap_or_else(|| home().join(".cache")).join("neko/record")
}

/// Where the webcam overlay's resize finds the recorded area
fn region_file() -> PathBuf {
    env_dir("XDG_RUNTIME_DIR").unwrap_or_else(state_dir).join("neko-screenrecord-region")
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_millis() as i64).unwrap_or(0)
}

fn read_json(path: &Path) -> Option<Value> {
    fs::read_to_string(path).ok().and_then(|text| serde_json::from_str(&text).ok())
}

/// Written whole and moved into place, so a reader never sees half of it
fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let dir = path.parent().ok_or("no directory to write in")?;
    fs::create_dir_all(dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
    let temp = dir.join(format!(".{}.new", path.file_name().unwrap_or_default().to_string_lossy()));
    let text = serde_json::to_string_pretty(value).map_err(|error| error.to_string())? + "\n";
    fs::write(&temp, text).map_err(|error| format!("can't write {}: {error}", temp.display()))?;
    fs::rename(&temp, path).map_err(|error| format!("can't write {}: {error}", path.display()))
}

/// Held while the state is read, changed and written: the take, the shell
/// and a key binding can all reach for it at once
struct Lock(#[allow(dead_code)] File);

impl Lock {
    fn take() -> Result<Lock, String> {
        let dir = runtime_dir();
        fs::create_dir_all(&dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(dir.join("record.lock"))
            .map_err(|error| format!("can't open the recorder's lock: {error}"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err("can't lock the recorder's state".into());
        }
        Ok(Lock(file))
    }
}

fn state_path() -> PathBuf {
    runtime_dir().join("record.json")
}

fn load_state() -> Map<String, Value> {
    match read_json(&state_path()) {
        Some(Value::Object(map)) => map,
        _ => idle(None),
    }
}

fn save_state(state: &Map<String, Value>) -> Result<(), String> {
    write_json(&state_path(), &Value::Object(state.clone()))?;
    // The bar's indicator asks rather than watches
    let _ = Command::new("neko-shell")
        .args(["-q", "neko.indicators", "refresh"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    Ok(())
}

/// Nothing going on; the last take saved and the last error stay on show
fn idle(previous: Option<&Map<String, Value>>) -> Map<String, Value> {
    let mut state = Map::new();
    state.insert("status".into(), json!("idle"));
    if let Some(last) = previous.and_then(|previous| previous.get("last")) {
        state.insert("last".into(), last.clone());
    }
    state
}

fn status_of(state: &Map<String, Value>) -> &str {
    state.get("status").and_then(Value::as_str).unwrap_or("idle")
}

fn int(state: &Map<String, Value>, key: &str) -> i64 {
    state.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn alive(pid: i64) -> bool {
    pid > 0 && unsafe { libc::kill(pid as i32, 0) } == 0
}

fn unit_active() -> bool {
    Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", &format!("{UNIT}.service")])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// A take whose process is gone (killed, or the machine went down) is over:
/// put the state back to idle rather than show a take that isn't running
fn reconcile(state: &mut Map<String, Value>) -> bool {
    let busy = match status_of(state) {
        "idle" => return false,
        // Still picking: the picker's process holds it
        "picking" => alive(int(state, "picker")),
        _ => unit_active(),
    };
    if !busy {
        let mut next = idle(Some(state));
        if status_of(state) != "picking" {
            next.insert("error".into(), json!("The last take ended without being saved."));
        }
        *state = next;
        let _ = save_state(state);
    }
    busy
}

fn have(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(program).is_file()))
        .unwrap_or(false)
}

fn output(program: &str, args: &[&str]) -> Option<String> {
    let result = Command::new(program).args(args).stderr(Stdio::null()).output().ok()?;
    result.status.success().then(|| String::from_utf8_lossy(&result.stdout).trim().to_string())
}

fn notify(urgency: &str, headline: &str, body: &str) {
    let _ = Command::new("neko-notification-send")
        .args(["-u", urgency, "-g", "󰻂", headline, body])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// --------------------------------------------------------------- settings

fn settings_path() -> PathBuf {
    state_dir().join("record-settings.json")
}

/// The videos folder: NEKO_SCREENRECORD_DIR, else XDG's, else ~/Videos
fn default_folder() -> String {
    if let Ok(dir) = std::env::var("NEKO_SCREENRECORD_DIR") {
        if !dir.is_empty() {
            return dir;
        }
    }
    output("xdg-user-dir", &["VIDEOS"])
        .filter(|dir| !dir.is_empty() && Path::new(dir) != home())
        .unwrap_or_else(|| home().join("Videos").display().to_string())
}

/// Every setting, the stored value where it's a valid one
fn load_settings() -> Map<String, Value> {
    let stored = match read_json(&settings_path()) {
        Some(Value::Object(map)) => map,
        _ => Map::new(),
    };
    let mut settings = Map::new();
    for (key, fallback, allowed) in SETTINGS {
        let value = stored.get(*key).and_then(Value::as_str).filter(|value| allowed.contains(value)).unwrap_or(fallback);
        settings.insert((*key).into(), json!(value));
    }
    let folder = stored
        .get("folder")
        .and_then(Value::as_str)
        .filter(|folder| folder.starts_with('/'))
        .map(str::to_string)
        .unwrap_or_else(default_folder);
    settings.insert("folder".into(), json!(folder));
    let device = stored.get("webcamDevice").and_then(Value::as_str).filter(|device| device.starts_with("/dev/")).unwrap_or("");
    settings.insert("webcamDevice".into(), json!(device));
    settings
}

/// One setting checked, as the stored one or a take's own `--set`
fn check_setting(key: &str, value: &str) -> Result<String, String> {
    if key == "folder" {
        let folder = value.strip_prefix("~/").map(|rest| home().join(rest)).unwrap_or_else(|| PathBuf::from(value));
        if !folder.is_absolute() {
            return Err("the folder needs a full path".into());
        }
        return Ok(folder.display().to_string());
    }
    if key == "webcamDevice" {
        return if value.is_empty() || value.starts_with("/dev/video") {
            Ok(value.to_string())
        } else {
            Err("webcamDevice is a /dev/video* device".into())
        };
    }
    let (_, _, allowed) = SETTINGS.iter().find(|(name, _, _)| *name == key).ok_or_else(|| format!("no setting called {key}"))?;
    if allowed.contains(&value) {
        Ok(value.to_string())
    } else {
        Err(format!("{key} is one of: {}", allowed.join(", ")))
    }
}

/// `--set key=value` pairs, which change one take without changing the settings
fn overrides(args: &[String]) -> Result<Vec<(String, String)>, String> {
    let mut pairs = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let pair = if arg == "--set" {
            rest.next().ok_or("--set needs key=value")?.clone()
        } else if let Some(pair) = arg.strip_prefix("--set=") {
            pair.to_string()
        } else {
            continue;
        };
        let (key, value) = pair.split_once('=').ok_or("--set needs key=value")?;
        pairs.push((key.to_string(), check_setting(key, value)?));
    }
    Ok(pairs)
}

fn on(settings: &Map<String, Value>, key: &str) -> bool {
    settings.get(key).and_then(Value::as_str) == Some("on")
}

fn setting<'a>(settings: &'a Map<String, Value>, key: &str) -> &'a str {
    settings.get(key).and_then(Value::as_str).unwrap_or("")
}

// ----------------------------------------------------------------- targets

/// What a take records: gpu-screen-recorder's -w value, and how to name it
struct Target {
    capture: String,
    kind: String,
    label: String,
}

fn monitors() -> Vec<Value> {
    output("hyprctl", &["monitors", "-j"])
        .and_then(|text| serde_json::from_str::<Vec<Value>>(&text).ok())
        .unwrap_or_default()
}

fn monitor_target(name: Option<&str>) -> Result<Target, String> {
    let all = monitors();
    let monitor = match name {
        Some(name) => all.iter().find(|monitor| monitor["name"].as_str() == Some(name)),
        None => all.iter().find(|monitor| monitor["focused"].as_bool() == Some(true)).or(all.first()),
    }
    .ok_or_else(|| format!("no display called {}", name.unwrap_or("that")))?;
    let name = monitor["name"].as_str().unwrap_or_default().to_string();
    let label = format!("{name} · {}×{}", monitor["width"].as_i64().unwrap_or(0), monitor["height"].as_i64().unwrap_or(0));
    Ok(Target { capture: name, kind: "monitor".into(), label })
}

/// The window exactly covering the rectangle, if one does: a click in the
/// picker snaps to a window's bounds
fn window_at(x: i64, y: i64, width: i64, height: i64) -> Option<String> {
    let clients: Vec<Value> = serde_json::from_str(&output("hyprctl", &["clients", "-j"])?).ok()?;
    clients
        .iter()
        .find(|client| {
            client["at"] == json!([x, y]) && client["size"] == json!([width, height]) && client["mapped"].as_bool() != Some(false)
        })
        .map(|client| {
            let class = client["class"].as_str().unwrap_or_default();
            let title = client["title"].as_str().unwrap_or_default();
            // The app, and which of its windows: a title alone can be just "~"
            let name = match (class.is_empty(), title.is_empty() || title == class) {
                (true, _) => title.to_string(),
                (false, true) => class.to_string(),
                (false, false) => format!("{class} · {title}"),
            };
            name.chars().take(48).collect()
        })
}

fn region_target(x: i64, y: i64, width: i64, height: i64) -> Result<Target, String> {
    if width < 16 || height < 16 {
        return Err("that area is too small to record".into());
    }
    // gpu-screen-recorder takes the area in the compositor's coordinates, as
    // the picker gives it, and scales it itself
    let capture = format!("{width}x{height}+{x}+{y}");
    Ok(match window_at(x, y, width, height) {
        Some(name) => Target { capture, kind: "window".into(), label: name },
        None => Target { capture, kind: "area".into(), label: format!("Area · {width}×{height}") },
    })
}

/// "X,Y WxH", as slurp and neko's picker print it
fn parse_rect(text: &str) -> Option<(i64, i64, i64, i64)> {
    let (position, size) = text.trim().split_once(' ')?;
    let (x, y) = position.split_once(',')?;
    let (width, height) = size.split_once('x')?;
    Some((x.parse().ok()?, y.parse().ok()?, width.parse().ok()?, height.parse().ok()?))
}

fn active_window_target() -> Result<Target, String> {
    let window: Value = serde_json::from_str(&output("hyprctl", &["activewindow", "-j"]).unwrap_or_default())
        .map_err(|_| "no window is focused")?;
    let (Some(x), Some(y), Some(width), Some(height)) =
        (window["at"][0].as_i64(), window["at"][1].as_i64(), window["size"][0].as_i64(), window["size"][1].as_i64())
    else {
        return Err("no window is focused".into());
    };
    region_target(x, y, width, height)
}

/// neko's picker: a click takes the window or display under it, a drag an
/// area. A cancelled pick is Ok(None).
fn pick() -> Result<Option<Target>, String> {
    let result = Command::new("neko-capture-region")
        .args(["smart", "--match-monitor"])
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("can't open the picker: {error}"))?;
    let text = String::from_utf8_lossy(&result.stdout).trim().to_string();
    if !result.status.success() || text.is_empty() {
        return Ok(None);
    }
    if let Some(name) = text.strip_prefix("monitor:") {
        return monitor_target(Some(name)).map(Some);
    }
    let (x, y, width, height) = parse_rect(&text).ok_or("the picker gave an area that can't be read")?;
    region_target(x, y, width, height).map(Some)
}

// ------------------------------------------------------------------- start

fn start(args: &[String]) -> Result<(), String> {
    if !have(RECORDER) {
        return Err(format!("{RECORDER} isn't installed; install it (install.sh offers it) to record the screen"));
    }
    let sets = overrides(args)?;
    {
        let _lock = Lock::take()?;
        let mut state = load_state();
        if reconcile(&mut state) {
            return Err("a take is already going; stop it first".into());
        }
        let mut next = idle(Some(&state));
        next.insert("status".into(), json!("picking"));
        next.insert("picker".into(), json!(std::process::id()));
        save_state(&next)?;
    }

    let monitor = args.iter().find_map(|arg| {
        if arg == "--monitor" { Some(None) } else { arg.strip_prefix("--monitor=").map(|name| Some(name.to_string())) }
    });
    let picked = if let Some(name) = monitor {
        monitor_target(name.as_deref()).map(Some)
    } else if args.iter().any(|arg| arg == "--window") {
        active_window_target().map(Some)
    } else {
        pick()
    };

    let back_to_idle = || {
        if let Ok(_lock) = Lock::take() {
            let state = load_state();
            let _ = save_state(&idle(Some(&state)));
        }
    };
    let target = match picked {
        Ok(Some(target)) => target,
        Ok(None) => {
            back_to_idle();
            return Ok(());
        }
        Err(error) => {
            back_to_idle();
            return Err(error);
        }
    };

    // The take as a unit of its own. Stopping the unit (a logout, say) sends
    // SIGINT, which gpu-screen-recorder answers by finishing its file, and
    // gives the save pass time to run.
    let program = std::env::current_exe().map_err(|error| format!("can't find neko-core: {error}"))?;
    let _ = Command::new("systemctl")
        .args(["--user", "reset-failed", &format!("{UNIT}.service")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let mut command = Command::new("systemd-run");
    command.args([
        "--user",
        "--quiet",
        "--collect",
        &format!("--unit={UNIT}"),
        "--property=KillSignal=SIGINT",
        "--property=TimeoutStopSec=300",
    ]);
    for name in [
        "NEKO_PATH",
        "PATH",
        "NEKO_QUICKSHELL",
        "NEKO_SCREENRECORD_DIR",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "DBUS_SESSION_BUS_ADDRESS",
        "XDG_RUNTIME_DIR",
    ] {
        if let Ok(value) = std::env::var(name) {
            command.arg(format!("--setenv={name}={value}"));
        }
    }
    command.arg(program).args(["record", "take", &target.capture, &target.kind, &target.label]);
    for (key, value) in &sets {
        command.args(["--set", &format!("{key}={value}")]);
    }
    let status = command
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| format!("can't run systemd-run: {error}"))?;
    if !status.success() {
        back_to_idle();
        return Err("systemd-run couldn't start the take".into());
    }
    // The unit holds the take from here, unless it has already said so itself
    update(|state| {
        if status_of(state) == "picking" {
            state.insert("status".into(), json!("starting"));
            state.remove("picker");
        }
    });
    Ok(())
}

// -------------------------------------------------------------------- take

extern "C" fn ignore_signal(_: libc::c_int) {}

/// The webcam in a corner, as a window the take records: mpv showing the
/// camera, which neko's webcam resize puts in place
fn start_webcam(target: &Target, size: &str, chosen: &str) -> Option<Child> {
    let device = if chosen.is_empty() {
        output("neko-capture-webcam-list", &[])?.lines().next()?.split_whitespace().next()?.to_string()
    } else {
        chosen.to_string()
    };
    let formats = output("v4l2-ctl", &["--list-formats-ext", "-d", &device]).unwrap_or_default();
    let mut options = "framerate=30".to_string();
    if let Some(resolution) = ["640x360", "1280x720", "1920x1080"].iter().find(|resolution| formats.contains(*resolution)) {
        options = format!("video_size={resolution},{options}");
    }
    let child = Command::new("mpv")
        .arg(format!("av://v4l2:{device}"))
        .args(["--profile=low-latency", "--untimed", "--no-cache"])
        .arg(format!("--demuxer-lavf-o={options}"))
        .arg("--vf=lavfi=[crop=ih*8/9:ih]")
        .arg("--title=WebcamOverlay")
        .arg(format!("--wayland-app-id=WebcamOverlay-{size}"))
        .args(["--no-border", "--no-audio", "--no-osc", "--osd-level=0", "--really-quiet"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // Placed before the take starts, or it's recorded sliding into its corner
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline
        && !output("hyprctl", &["clients", "-j"]).is_some_and(|text| text.contains("\"title\": \"WebcamOverlay\""))
    {
        sleep(Duration::from_millis(50));
    }
    if target.kind != "monitor" {
        let _ = fs::write(region_file(), &target.capture);
    }
    let _ = Command::new("neko-capture-webcam-resize").arg(size).stdout(Stdio::null()).stderr(Stdio::null()).status();
    sleep(Duration::from_millis(600));
    Some(child)
}

fn stop_webcam(webcam: Option<Child>) {
    if let Some(mut child) = webcam {
        let _ = child.kill();
        let _ = child.wait();
    }
    let _ = fs::remove_file(region_file());
}

/// A name in the folder nothing has yet
fn take_name(folder: &Path, container: &str) -> PathBuf {
    let base = format!("screenrecording-{}", Local::now().format("%Y-%m-%d_%H-%M-%S"));
    let mut path = folder.join(format!("{base}.{container}"));
    let mut suffix = 2;
    while path.exists() {
        path = folder.join(format!("{base}-{suffix}.{container}"));
        suffix += 1;
    }
    path
}

/// The recording while it's made, hidden beside where the take is saved
fn part_name(output: &Path) -> PathBuf {
    let name = output.file_name().unwrap_or_default().to_string_lossy();
    output.with_file_name(format!(".{name}.part"))
}

fn recorder_args(target: &Target, settings: &Map<String, Value>, part: &Path) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-w".into(),
        target.capture.clone(),
        "-c".into(),
        setting(settings, "container").into(),
        "-f".into(),
        setting(settings, "fps").into(),
        "-fm".into(),
        "cfr".into(),
        "-k".into(),
        setting(settings, "codec").into(),
        "-q".into(),
        setting(settings, "quality").into(),
        "-cursor".into(),
        if on(settings, "cursor") { "yes" } else { "no" }.into(),
        "-fallback-cpu-encoding".into(),
        "yes".into(),
        "-o".into(),
        part.display().to_string(),
    ];
    // Displays past 4K record at 4K: the encoders top out there
    if target.kind == "monitor" {
        if let Some(monitor) = monitors().iter().find(|monitor| monitor["name"].as_str() == Some(&target.capture)) {
            if monitor["width"].as_i64().unwrap_or(0) > 3840 || monitor["height"].as_i64().unwrap_or(0) > 2160 {
                args.extend(["-s".into(), "3840x2160".into()]);
            }
        }
    }
    let mut devices = Vec::new();
    if on(settings, "desktopAudio") {
        devices.push("default_output");
    }
    if on(settings, "microphone") {
        devices.push("default_input");
    }
    // One track: most players only play the first of several
    if !devices.is_empty() {
        args.extend(["-a".into(), devices.join("|"), "-ac".into(), "aac".into()]);
    }
    args
}

/// Changes the live state under the lock
fn update(change: impl FnOnce(&mut Map<String, Value>)) {
    if let Ok(_lock) = Lock::take() {
        let mut state = load_state();
        change(&mut state);
        let _ = save_state(&state);
    }
}

fn discarded() -> bool {
    load_state().get("discard").and_then(Value::as_bool) == Some(true)
}

fn take(args: &[String]) -> Result<(), String> {
    let (Some(capture), Some(kind), Some(label)) = (args.first(), args.get(1), args.get(2)) else {
        return Err("usage: neko-core record take <target> <kind> <label> [--set key=value]...".into());
    };
    let target = Target { capture: capture.clone(), kind: kind.clone(), label: label.clone() };
    let mut settings = load_settings();
    for (key, value) in overrides(&args[3..])? {
        settings.insert(key, json!(value));
    }
    // Stopping the unit sends SIGINT to everything in it: the recorder ends
    // its file on it, and this process goes on to save it rather than die
    unsafe {
        libc::signal(libc::SIGINT, ignore_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, ignore_signal as *const () as libc::sighandler_t);
    }

    let folder = PathBuf::from(setting(&settings, "folder"));
    let fail = |message: String| {
        update(|state| {
            let mut next = idle(Some(state));
            next.insert("error".into(), json!(message.clone()));
            *state = next;
        });
        notify("critical", "Screen recording failed", &message);
        Err(message.clone())
    };
    if let Err(error) = fs::create_dir_all(&folder) {
        return fail(format!("can't use {}: {error}", folder.display()));
    }
    let output = take_name(&folder, setting(&settings, "container"));
    let part = part_name(&output);

    let webcam = if on(&settings, "webcam") { start_webcam(&target, setting(&settings, "webcamSize"), setting(&settings, "webcamDevice")) } else { None };

    // The countdown, before the recorder starts, so none of it is recorded
    let countdown: i64 = setting(&settings, "countdown").parse().unwrap_or(0);
    let pid = std::process::id() as i64;
    update(|state| {
        let mut next = idle(Some(state));
        next.insert("status".into(), json!(if countdown > 0 { "countdown" } else { "starting" }));
        next.insert("holder".into(), json!(pid));
        next.insert("countdownEnds".into(), json!(now_ms() + countdown * 1000));
        next.insert("target".into(), json!(target.capture));
        next.insert("kind".into(), json!(target.kind));
        next.insert("label".into(), json!(target.label));
        next.insert("output".into(), json!(output.display().to_string()));
        *state = next;
    });
    let counted = Instant::now() + Duration::from_secs(countdown as u64);
    while Instant::now() < counted {
        if discarded() {
            stop_webcam(webcam);
            update(|state| *state = idle(Some(state)));
            return Ok(());
        }
        sleep(Duration::from_millis(100));
    }

    let log = runtime_dir().join("record.log");
    let errors = File::create(&log).map(Stdio::from).unwrap_or_else(|_| Stdio::null());
    let mut recorder = match Command::new(RECORDER)
        .args(recorder_args(&target, &settings, &part))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(errors)
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            stop_webcam(webcam);
            return fail(format!("{RECORDER} didn't start: {error}"));
        }
    };
    let recorder_pid = recorder.id() as i64;

    // Recording only once there's a file: until then the recorder may still fail
    let deadline = Instant::now() + START_LIMIT;
    let mut exited = None;
    while !part.exists() && Instant::now() < deadline {
        if let Ok(Some(status)) = recorder.try_wait() {
            exited = Some(status);
            break;
        }
        if discarded() {
            unsafe { libc::kill(recorder_pid as i32, libc::SIGINT) };
        }
        sleep(Duration::from_millis(100));
    }
    if exited.is_some() || !part.exists() {
        if exited.is_none() {
            let _ = recorder.kill();
        }
        let _ = recorder.wait();
        let _ = fs::remove_file(&part);
        stop_webcam(webcam);
        if discarded() {
            update(|state| *state = idle(Some(state)));
            return Ok(());
        }
        let why = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .rev()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| "no reason given".into());
        return fail(format!("{RECORDER} stopped before recording: {why}"));
    }

    update(|state| {
        state.insert("status".into(), json!("recording"));
        state.insert("pid".into(), json!(recorder_pid));
        state.insert("startedAt".into(), json!(now_ms()));
        state.insert("pausedMs".into(), json!(0));
        state.insert("audio".into(), json!(on(&settings, "desktopAudio") || on(&settings, "microphone")));
        state.remove("countdownEnds");
    });

    let _ = recorder.wait();
    stop_webcam(webcam);

    let finished = load_state();
    if finished.get("discard").and_then(Value::as_bool) == Some(true) {
        let _ = fs::remove_file(&part);
        update(|state| *state = idle(Some(state)));
        return Ok(());
    }
    let recorded_ms = {
        let paused = int(&finished, "pausedMs")
            + if status_of(&finished) == "paused" { now_ms() - int(&finished, "pausedAt") } else { 0 };
        (now_ms() - int(&finished, "startedAt") - paused).max(0)
    };
    update(|state| {
        state.insert("status".into(), json!("saving"));
        state.insert("recordedMs".into(), json!(recorded_ms));
    });

    let noise = on(&settings, "noiseReduction") && on(&settings, "microphone");
    if !finish(&part, &output, noise) {
        // Keep what was recorded, as it came, rather than lose it
        let _ = fs::rename(&part, &output);
    }
    let _ = fs::remove_file(&part);

    let thumb = thumbnail(&output);
    let duration_ms = duration_ms(&output).unwrap_or(recorded_ms);
    let entry = json!({
        "file": output.display().to_string(),
        "thumb": thumb.as_ref().map(|path| path.display().to_string()).unwrap_or_default(),
        "durationMs": duration_ms,
        "size": fs::metadata(&output).map(|meta| meta.len()).unwrap_or(0),
        "createdAt": now_ms(),
        "kind": target.kind,
        "label": target.label,
    });
    add_history(&entry);
    update(|state| {
        let mut next = idle(None);
        next.insert("last".into(), entry.clone());
        *state = next;
    });

    let mut notice = Command::new("neko-notification-send");
    notice.args(["-g", "󰻂", "-t", "10000"]);
    if let Some(thumb) = &thumb {
        notice.arg("--image").arg(thumb);
    }
    notice.args(["Screen recording saved", &format!("{} · {}", target.label, clock_text(duration_ms))]);
    notice.args(["--exec", "xdg-open"]).arg(&output);
    let _ = notice.stdout(Stdio::null()).stderr(Stdio::null()).status();
    Ok(())
}

// --------------------------------------------------------------- the save

fn probe(file: &Path, args: &[&str]) -> String {
    let mut all: Vec<&str> = vec!["-v", "error"];
    all.extend_from_slice(args);
    let file = file.display().to_string();
    all.push(&file);
    output("ffprobe", &all).unwrap_or_default()
}

/// The audio pass: the first moments muted (capture opening pops), an
/// optional pass against steady background noise, then even loudness
fn audio_filter(noise: bool) -> String {
    let mut filter = String::from("volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05");
    if noise {
        filter.push_str(",afftdn=nf=-30");
    }
    filter.push_str(",loudnorm=I=-14:TP=-1.5:LRA=11");
    filter
}

/// The saved file: the recorder's first frame trimmed and the audio pass run.
/// The video is copied as it is unless the first group of frames carries ones
/// marked for discarding, which copying can't drop.
fn finish(part: &Path, output: &Path, noise: bool) -> bool {
    if !have("ffmpeg") {
        return false;
    }
    let reencode = probe(part, &["-select_streams", "v:0", "-read_intervals", "%+0.2", "-show_entries", "packet=flags", "-of", "csv=p=0"])
        .contains('D');
    let audio = probe(part, &["-select_streams", "a", "-show_entries", "stream=codec_type", "-of", "csv=p=0"]).contains("audio");
    let duration: f64 = probe(part, &["-show_entries", "format=duration", "-of", "csv=p=0"]).parse().unwrap_or(0.0);
    let short = duration > 0.0 && duration < 0.8;

    let work = output.with_file_name(format!(".{}.work", output.file_name().unwrap_or_default().to_string_lossy()));
    let extension = output.extension().map(|ext| ext.to_string_lossy().to_string()).unwrap_or_default();
    let attempt = |with_audio: bool| -> bool {
        let mut args: Vec<String> = vec!["-y".into(), "-loglevel".into(), "error".into()];
        if !short {
            args.extend(["-ss".into(), "0.1".into()]);
        }
        args.extend(["-i".into(), part.display().to_string()]);
        if reencode {
            args.extend(["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"].map(String::from));
        } else {
            args.extend(["-c:v".into(), "copy".into()]);
        }
        if with_audio {
            args.extend(["-af".into(), audio_filter(noise), "-c:a".into(), "aac".into(), "-b:a".into(), "192k".into()]);
        } else {
            args.push("-an".into());
        }
        if extension == "mp4" {
            args.extend(["-movflags".into(), "+faststart".into()]);
        }
        args.extend(["-f".into(), if extension == "mkv" { "matroska" } else { "mp4" }.into()]);
        args.push(work.display().to_string());
        Command::new("ffmpeg")
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    };
    // A take too short to carry sound well is saved silent; a failed audio
    // pass falls back to the picture alone
    let mut saved = attempt(audio && !short);
    if !saved && audio && !short {
        saved = attempt(false);
    }
    let valid = saved && probe(&work, &["-select_streams", "v:0", "-show_entries", "stream=codec_type", "-of", "csv=p=0"]).contains("video");
    if valid && fs::rename(&work, output).is_ok() {
        return true;
    }
    let _ = fs::remove_file(&work);
    false
}

fn duration_ms(file: &Path) -> Option<i64> {
    let seconds: f64 = probe(file, &["-show_entries", "format=duration", "-of", "csv=p=0"]).parse().ok()?;
    Some((seconds * 1000.0).round() as i64)
}

/// A small picture of the take for the history, from just after its start
fn thumbnail(file: &Path) -> Option<PathBuf> {
    let dir = thumb_dir();
    fs::create_dir_all(&dir).ok()?;
    let stem = file.file_stem()?.to_string_lossy().to_string();
    let thumb = dir.join(format!("{stem}.jpg"));
    let made = |at: &str| {
        Command::new("ffmpeg")
            .args(["-y", "-loglevel", "error", "-ss", at, "-i"])
            .arg(file)
            .args(["-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4"])
            .arg(&thumb)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
            && thumb.exists()
    };
    (made("0.5") || made("0")).then_some(thumb)
}

fn clock_text(ms: i64) -> String {
    let total = ms.max(0) / 1000;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 { format!("{hours}:{minutes:02}:{seconds:02}") } else { format!("{minutes}:{seconds:02}") }
}

// ----------------------------------------------------------------- history

fn history_path() -> PathBuf {
    state_dir().join("record-history.json")
}

fn load_history() -> Vec<Value> {
    match read_json(&history_path()) {
        Some(Value::Array(entries)) => entries,
        _ => Vec::new(),
    }
}

fn add_history(entry: &Value) {
    let mut entries = load_history();
    entries.insert(0, entry.clone());
    entries.truncate(MAX_HISTORY);
    let _ = write_json(&history_path(), &Value::Array(entries));
}

fn history(limit: usize) -> Value {
    Value::Array(
        load_history()
            .into_iter()
            .filter(|entry| entry["file"].as_str().is_some_and(|file| Path::new(file).is_file()))
            .take(limit)
            .collect(),
    )
}

/// Only a take in the history: nothing else can be named to delete
fn trash(file: &str) -> Result<(), String> {
    let mut entries = load_history();
    let index = entries.iter().position(|entry| entry["file"].as_str() == Some(file)).ok_or("that isn't a take in the history")?;
    let entry = entries.remove(index);
    if Path::new(file).exists() {
        let trashed = have("gio") && Command::new("gio").args(["trash", file]).stderr(Stdio::null()).status().is_ok_and(|status| status.success());
        if !trashed {
            fs::remove_file(file).map_err(|error| format!("can't remove {file}: {error}"))?;
        }
    }
    if let Some(thumb) = entry["thumb"].as_str().filter(|thumb| !thumb.is_empty()) {
        let _ = fs::remove_file(thumb);
    }
    write_json(&history_path(), &Value::Array(entries))?;
    // The last take shown in the panel goes with it
    let _lock = Lock::take()?;
    let mut state = load_state();
    if state.get("last").and_then(|last| last["file"].as_str()) == Some(file) {
        state.remove("last");
        save_state(&state)?;
    }
    Ok(())
}

// ------------------------------------------------------- pause and stop

fn signal_recorder(state: &Map<String, Value>, signal: libc::c_int) -> bool {
    let pid = int(state, "pid");
    alive(pid) && unsafe { libc::kill(pid as i32, signal) } == 0
}

/// gpu-screen-recorder pauses and resumes on SIGUSR2, the file carrying on
fn set_paused(want: Option<bool>) -> Result<(), String> {
    let _lock = Lock::take()?;
    let mut state = load_state();
    let status = status_of(&state).to_string();
    if status != "recording" && status != "paused" {
        return Err("nothing is recording".into());
    }
    let paused = status == "paused";
    let pause = want.unwrap_or(!paused);
    if pause == paused {
        return Ok(());
    }
    if !signal_recorder(&state, libc::SIGUSR2) {
        return Err("the recorder isn't running".into());
    }
    let now = now_ms();
    if pause {
        state.insert("status".into(), json!("paused"));
        state.insert("pausedAt".into(), json!(now));
    } else {
        let total = int(&state, "pausedMs") + (now - int(&state, "pausedAt")).max(0);
        state.insert("status".into(), json!("recording"));
        state.insert("pausedMs".into(), json!(total));
        state.remove("pausedAt");
    }
    save_state(&state)
}

fn stop(discard: bool) -> Result<(), String> {
    let _lock = Lock::take()?;
    let mut state = load_state();
    if !reconcile(&mut state) {
        return Err("nothing is recording".into());
    }
    match status_of(&state) {
        "picking" => Err("the picker is still open".into()),
        "saving" => Ok(()),
        "countdown" | "starting" => {
            // Not recording yet: there's nothing to keep
            state.insert("discard".into(), json!(true));
            save_state(&state)?;
            signal_recorder(&state, libc::SIGINT);
            Ok(())
        }
        _ => {
            if discard {
                state.insert("discard".into(), json!(true));
                save_state(&state)?;
            }
            // SIGINT is how gpu-screen-recorder finishes its file
            if signal_recorder(&state, libc::SIGINT) { Ok(()) } else { Err("the recorder isn't running".into()) }
        }
    }
}

// ----------------------------------------------------------------- command

fn status() -> Result<Value, String> {
    let mut state = {
        let _lock = Lock::take()?;
        let mut state = load_state();
        reconcile(&mut state);
        state
    };
    state.insert("settings".into(), Value::Object(load_settings()));
    state.insert("available".into(), json!(have(RECORDER)));
    state.insert("now".into(), json!(now_ms()));
    Ok(Value::Object(state))
}

fn print(value: &Value) -> Result<(), String> {
    println!("{}", serde_json::to_string(value).map_err(|error| error.to_string())?);
    Ok(())
}

pub fn run(args: &[String]) -> Result<(), String> {
    let Some((verb, rest)) = args.split_first() else {
        return Err("usage: neko-core record <status|start|toggle|stop|pause|resume|toggle-pause|history|trash|set>".into());
    };
    match verb.as_str() {
        "status" => print(&status()?),
        "start" => start(rest),
        "toggle" => {
            let busy = {
                let _lock = Lock::take()?;
                let mut state = load_state();
                reconcile(&mut state)
            };
            if busy { stop(false) } else { start(rest) }
        }
        "stop" => stop(rest.iter().any(|arg| arg == "--discard")),
        "pause" => set_paused(Some(true)),
        "resume" => set_paused(Some(false)),
        "toggle-pause" => set_paused(None),
        "take" => take(rest),
        "history" => print(&history(rest.first().and_then(|limit| limit.parse().ok()).unwrap_or(MAX_HISTORY))),
        "trash" => trash(rest.first().ok_or("which take?")?),
        "set" => {
            let (Some(key), Some(value)) = (rest.first(), rest.get(1)) else {
                return Err("usage: neko-core record set <key> <value>".into());
            };
            let value = check_setting(key, value)?;
            let mut settings = match read_json(&settings_path()) {
                Some(Value::Object(map)) => map,
                _ => Map::new(),
            };
            settings.insert(key.clone(), json!(value));
            write_json(&settings_path(), &Value::Object(settings))
        }
        other => Err(format!("unknown record command: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_pickers_rectangle() {
        assert_eq!(parse_rect("10,-20 300x200\n"), Some((10, -20, 300, 200)));
        assert_eq!(parse_rect("monitor:DP-1"), None);
    }

    #[test]
    fn checks_settings() {
        assert_eq!(check_setting("fps", "60").as_deref(), Ok("60"));
        assert!(check_setting("fps", "59").is_err());
        assert!(check_setting("nope", "on").is_err());
        assert!(check_setting("folder", "videos").is_err());
        assert!(check_setting("folder", "/tmp/videos").is_ok());
    }

    #[test]
    fn reads_overrides() {
        let args: Vec<String> = ["--monitor", "--set", "microphone=on", "--set=countdown=0"].map(String::from).to_vec();
        assert_eq!(overrides(&args), Ok(vec![("microphone".into(), "on".into()), ("countdown".into(), "0".into())]));
        assert!(overrides(&["--set".to_string(), "fps=1".to_string()]).is_err());
    }

    #[test]
    fn names_a_hidden_part() {
        assert_eq!(part_name(Path::new("/v/a.mp4")), PathBuf::from("/v/.a.mp4.part"));
    }

    #[test]
    fn formats_durations() {
        assert_eq!(clock_text(65_000), "1:05");
        assert_eq!(clock_text(3_725_000), "1:02:05");
    }

    #[test]
    fn mutes_the_start_and_evens_the_rest() {
        assert!(audio_filter(false).ends_with("loudnorm=I=-14:TP=-1.5:LRA=11"));
        assert!(audio_filter(true).contains("afftdn"));
    }
}
