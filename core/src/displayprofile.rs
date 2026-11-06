//! `neko-core display-profile`: named display layouts, matched to the displays
//! connected by what they are (make, model and serial), not the connector they
//! happen to be on. A profile is applied through neko-display, which keeps
//! each display's settings; while automatic switching is on, a watcher (the
//! neko-display-profiles unit) applies the profile that fits whenever a
//! display comes or goes.
//!
//! Profiles are in ~/.config/neko/display-profiles.json.
//!
//!   list                  the profiles, how well each fits the displays
//!                         connected now, and which fits best, as JSON
//!   save <name>           the layout now, as that profile (replacing one
//!                         of the same name)
//!   apply <name>          set the displays as the profile has them
//!   apply-best            apply the profile that fits the displays exactly,
//!                         if there's one
//!   delete <name>
//!   rename <name> <new name>
//!   auto on|off           switch automatically, starting or stopping the watcher
//!   start|stop            the watcher, as neko-session runs it
//!   watch                 the watcher itself

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use serde_json::{Map, Value, json};

const UNIT: &str = "neko-display-profiles";
const MAX_NAME: usize = 40;
/// Displays come up one by one, docks most of all: wait for them to settle
const SETTLE: Duration = Duration::from_millis(2500);

// Scores: a display the profile turns on and that
// is here counts most; one it keeps off, half; one it wants that isn't here,
// or one here it doesn't know, counts against it
const ENABLED_MATCH: i64 = 100;
const DISABLED_MATCH: i64 = 50;
const MISSING: i64 = -30;
const MISSING_OFF: i64 = -10;
const UNKNOWN: i64 = -20;

/// What neko-display keeps per display, which a profile carries along
const CARRIED: &[&str] = &[
    "bitdepth",
    "vrr",
    "cm",
    "sdr_eotf",
    "sdrbrightness",
    "sdrsaturation",
    "sdr_min_luminance",
    "sdr_max_luminance",
    "min_luminance",
    "max_luminance",
    "max_avg_luminance",
    "supports_hdr",
    "supports_wide_color",
    "icc",
    "reserved_area",
];

fn config_dir() -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".config"))
        .join("neko")
}

fn store_path() -> PathBuf {
    config_dir().join("display-profiles.json")
}

fn load() -> Map<String, Value> {
    let mut store = fs::read_to_string(store_path())
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    store.entry("auto").or_insert(json!(true));
    store.entry("profiles").or_insert(json!([]));
    store
}

/// Held while the profiles are read, changed and written: the watcher and a
/// save from the panel can reach for them at once. It lasts while it's open.
struct Lock(#[allow(dead_code)] File);

impl Lock {
    fn take() -> Result<Lock, String> {
        let dir = config_dir();
        fs::create_dir_all(&dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(dir.join(".display-profiles.lock"))
            .map_err(|error| format!("can't open the profiles' lock: {error}"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err("can't lock the display profiles".into());
        }
        Ok(Lock(file))
    }
}

/// The profiles read afresh, changed and written back under the lock, so a
/// change made meanwhile (a save, auto off) isn't written over
fn change(edit: impl FnOnce(&mut Map<String, Value>) -> Result<(), String>) -> Result<(), String> {
    let _lock = Lock::take()?;
    let mut store = load();
    edit(&mut store)?;
    save_store(&store)
}

/// Written whole and moved into place
fn save_store(store: &Map<String, Value>) -> Result<(), String> {
    let dir = config_dir();
    fs::create_dir_all(&dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
    let temp = dir.join(format!(".display-profiles.json.{}", std::process::id()));
    let text = serde_json::to_string_pretty(&Value::Object(store.clone())).map_err(|error| error.to_string())? + "\n";
    fs::write(&temp, text).map_err(|error| format!("can't write {}: {error}", temp.display()))?;
    fs::rename(&temp, store_path()).map_err(|error| format!("can't write {}: {error}", store_path().display()))
}

fn profiles(store: &Map<String, Value>) -> Vec<Value> {
    store.get("profiles").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn find<'a>(list: &'a [Value], name: &str) -> Option<&'a Value> {
    list.iter().find(|profile| profile["name"].as_str().is_some_and(|other| other.eq_ignore_ascii_case(name)))
}

fn clean_name(name: &str) -> Result<String, String> {
    let name: String = name.trim().chars().filter(|ch| !ch.is_control()).take(MAX_NAME).collect();
    if name.is_empty() { Err("a profile needs a name".into()) } else { Ok(name) }
}

// ----------------------------------------------------------- the displays

fn output(program: &str, args: &[&str]) -> Option<String> {
    let result = Command::new(program).args(args).stderr(Stdio::null()).output().ok()?;
    result.status.success().then(|| String::from_utf8_lossy(&result.stdout).to_string())
}

/// Every display Hyprland knows, on or off
fn monitors() -> Result<Vec<Value>, String> {
    let text = output("hyprctl", &["monitors", "all", "-j"]).ok_or("can't ask Hyprland for its displays")?;
    serde_json::from_str(&text).map_err(|error| format!("can't read Hyprland's displays: {error}"))
}

fn clean_part(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// What a display is, whichever connector it's on: make, model and serial,
/// else its description, else (as a last resort) the connector
fn hardware_key(make: &str, model: &str, serial: &str, description: &str, name: &str) -> String {
    let parts: Vec<String> = [make, model, serial].iter().map(|part| clean_part(part)).filter(|part| !part.is_empty()).collect();
    if !parts.is_empty() {
        return parts.join("|");
    }
    let description = clean_part(description);
    if !description.is_empty() { description } else { clean_part(name) }
}

fn monitor_key(monitor: &Value) -> String {
    let field = |key: &str| monitor[key].as_str().unwrap_or_default().to_string();
    hardware_key(&field("make"), &field("model"), &field("serial"), &field("description"), &field("name"))
}

fn is_builtin(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with("edp") || name.starts_with("lvds") || name.starts_with("dsi")
}

/// neko-display's saved settings, per connector
fn saved_settings() -> Map<String, Value> {
    fs::read_to_string(config_dir().join("displays.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

/// The layout as it is now, as a profile's outputs
fn snapshot() -> Result<Vec<Value>, String> {
    let all = monitors()?;
    let saved = saved_settings();
    let names: HashMap<i64, String> = all
        .iter()
        .filter_map(|monitor| Some((monitor["id"].as_i64()?, monitor["name"].as_str()?.to_string())))
        .collect();
    Ok(all
        .iter()
        .filter(|monitor| monitor["name"].as_str() != Some("FALLBACK"))
        .map(|monitor| {
            let name = monitor["name"].as_str().unwrap_or_default();
            let enabled = monitor["disabled"].as_bool() != Some(true);
            let mut settings = Map::new();
            if let Some(Value::Object(kept)) = saved.get(name) {
                for key in CARRIED {
                    if let Some(value) = kept.get(*key) {
                        settings.insert((*key).into(), value.clone());
                    }
                }
            }
            if enabled {
                let rate = monitor["refreshRate"].as_f64().unwrap_or(60.0);
                settings.insert(
                    "mode".into(),
                    json!(format!("{}x{}@{:.2}", monitor["width"].as_i64().unwrap_or(0), monitor["height"].as_i64().unwrap_or(0), rate)),
                );
                settings.insert("position".into(), json!(format!("{}x{}", monitor["x"].as_i64().unwrap_or(0), monitor["y"].as_i64().unwrap_or(0))));
                settings.insert("scale".into(), monitor["scale"].clone());
                settings.insert("transform".into(), monitor["transform"].clone());
                // Hyprland gives the mirrored display's id, not its name
                let mirrored = match &monitor["mirrorOf"] {
                    Value::String(text) => text.parse::<i64>().ok().and_then(|id| names.get(&id).cloned()),
                    Value::Number(id) => id.as_i64().and_then(|id| names.get(&id).cloned()),
                    _ => None,
                };
                if let Some(mirrored) = mirrored {
                    settings.insert("mirror".into(), json!(mirrored));
                }
            }
            json!({
                "key": monitor_key(monitor),
                "name": name,
                "description": clean_part(monitor["description"].as_str().unwrap_or_default()),
                "enabled": enabled,
                "settings": settings,
            })
        })
        .collect())
}

// ---------------------------------------------------------------- matching

#[derive(Debug, Default, PartialEq)]
struct Fit {
    score: i64,
    /// Every display here is in the profile and every one it turns on is here
    exact: bool,
}

/// How well a profile fits the displays here, by hardware key. A profile that
/// turns on none of them doesn't fit at all.
fn fit(outputs: &[Value], connected: &[String]) -> Fit {
    let mut here: HashMap<&str, i64> = HashMap::new();
    for key in connected {
        *here.entry(key.as_str()).or_default() += 1;
    }
    let mut known: HashMap<&str, i64> = HashMap::new();
    let mut on: HashMap<&str, i64> = HashMap::new();
    for output in outputs {
        let key = output["key"].as_str().unwrap_or_default();
        *known.entry(key).or_default() += 1;
        if output["enabled"].as_bool() == Some(true) {
            *on.entry(key).or_default() += 1;
        }
    }
    let (mut enabled, mut disabled, mut unknown) = (0, 0, 0);
    for (key, count) in &here {
        let lit = (*count).min(*on.get(key).unwrap_or(&0));
        let kept_off = (count - lit).min(known.get(key).unwrap_or(&0) - on.get(key).unwrap_or(&0)).max(0);
        enabled += lit;
        disabled += kept_off;
        unknown += (count - known.get(key).unwrap_or(&0)).max(0);
    }
    let mut missing = 0;
    for (key, wanted) in &on {
        missing += (wanted - here.get(key).unwrap_or(&0)).max(0);
    }
    let mut missing_off = 0;
    for (key, count) in &known {
        let wanted_off = count - on.get(key).unwrap_or(&0);
        if wanted_off > 0 {
            let present = *here.get(key).unwrap_or(&0);
            let spare = (present - present.min(*on.get(key).unwrap_or(&0))).max(0);
            missing_off += (wanted_off - spare).max(0);
        }
    }
    if enabled == 0 {
        return Fit::default();
    }
    Fit {
        score: enabled * ENABLED_MATCH + disabled * DISABLED_MATCH + missing * MISSING + missing_off * MISSING_OFF + unknown * UNKNOWN,
        exact: missing == 0 && missing_off == 0 && unknown == 0,
    }
}

fn outputs_of(profile: &Value) -> Vec<Value> {
    profile["outputs"].as_array().cloned().unwrap_or_default()
}

/// The profile that fits best, exact fits first, then by score, then by name
fn best<'a>(list: &'a [Value], connected: &[String], exact_only: bool) -> Option<&'a Value> {
    let mut scored: Vec<(&Value, Fit)> = list
        .iter()
        .map(|profile| (profile, fit(&outputs_of(profile), connected)))
        .filter(|(_, fit)| fit.score > 0 && (fit.exact || !exact_only))
        .collect();
    scored.sort_by(|(a, fa), (b, fb)| {
        fb.exact
            .cmp(&fa.exact)
            .then(fb.score.cmp(&fa.score))
            .then(a["name"].as_str().unwrap_or_default().to_lowercase().cmp(&b["name"].as_str().unwrap_or_default().to_lowercase()))
    });
    scored.first().map(|(profile, _)| *profile)
}

// ---------------------------------------------------------------- applying

/// Which connector each of the profile's outputs is on now: by hardware key,
/// and where two displays share one, the connector it was saved on first
fn assign(outputs: &[Value], monitors: &[Value]) -> Vec<(Value, String)> {
    let mut free: Vec<(String, String)> = monitors
        .iter()
        .filter(|monitor| monitor["name"].as_str() != Some("FALLBACK"))
        .map(|monitor| (monitor_key(monitor), monitor["name"].as_str().unwrap_or_default().to_string()))
        .collect();
    let mut pairs = Vec::new();
    let mut rest = Vec::new();
    for output in outputs {
        let key = output["key"].as_str().unwrap_or_default();
        let saved_on = output["name"].as_str().unwrap_or_default();
        if let Some(index) = free.iter().position(|(other, name)| other == key && name == saved_on) {
            pairs.push((output.clone(), free.remove(index).1));
        } else {
            rest.push(output);
        }
    }
    for output in rest {
        let key = output["key"].as_str().unwrap_or_default();
        if let Some(index) = free.iter().position(|(other, _)| other == key) {
            pairs.push((output.clone(), free.remove(index).1));
        }
    }
    pairs
}

fn setting_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(flag) => flag.to_string(),
        other => other.to_string(),
    }
}

fn neko_display(args: &[String]) -> Result<(), String> {
    let result = Command::new("neko-display")
        .args(args)
        .stdout(Stdio::null())
        .output()
        .map_err(|error| format!("can't run neko-display: {error}"))?;
    if result.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&result.stderr).trim().to_string())
    }
}

/// The profile's displays on, set and placed, then the ones it keeps off off:
/// so the screen never goes dark between the two
fn apply(profile: &Value) -> Result<(), String> {
    let monitors = monitors()?;
    let pairs = assign(&outputs_of(profile), &monitors);
    let lit: Vec<&(Value, String)> = pairs.iter().filter(|(output, _)| output["enabled"].as_bool() == Some(true)).collect();
    if lit.is_empty() {
        return Err("none of the displays this profile turns on is connected".into());
    }

    let mut placements = Vec::new();
    // Mirrors last: the display they show has to be set first
    let mut ordered = lit.clone();
    ordered.sort_by_key(|(output, _)| output["settings"].get("mirror").is_some());
    for (output, connector) in ordered {
        let settings = output["settings"].as_object().cloned().unwrap_or_default();
        let mut args = vec!["set".to_string(), connector.clone(), "disabled=false".to_string()];
        let mirrors = settings.contains_key("mirror");
        for (key, value) in &settings {
            // A mirror shows another display, so it has no place of its own
            if key == "position" {
                if !mirrors {
                    placements.push(format!("{connector}={}", setting_text(value)));
                }
                continue;
            }
            // The mirrored display by its connector now, not the one it was saved on
            if key == "mirror" {
                let saved_on = setting_text(value);
                let now = outputs_of(profile)
                    .iter()
                    .find(|other| other["name"].as_str() == Some(saved_on.as_str()))
                    .and_then(|other| pairs.iter().find(|(paired, _)| paired == other).map(|(_, name)| name.clone()));
                if let Some(now) = now {
                    args.push(format!("mirror={now}"));
                }
                continue;
            }
            args.push(format!("{key}={}", setting_text(value)));
        }
        neko_display(&args)?;
    }
    if !placements.is_empty() {
        let mut args = vec!["place".to_string()];
        args.extend(placements);
        neko_display(&args)?;
    }
    for (output, connector) in &pairs {
        if output["enabled"].as_bool() != Some(true) {
            neko_display(&["set".into(), connector.clone(), "disabled=true".into()])?;
        }
    }
    Ok(())
}

fn connected_keys() -> Result<Vec<String>, String> {
    Ok(monitors()?.iter().filter(|monitor| monitor["name"].as_str() != Some("FALLBACK")).map(monitor_key).collect())
}

fn apply_named(name: &str) -> Result<(), String> {
    let list = profiles(&load());
    let profile = find(&list, name).ok_or_else(|| format!("no profile called {name}"))?.clone();
    apply(&profile)?;
    change(|store| {
        store.insert("last".into(), profile["name"].clone());
        Ok(())
    })
}

/// The profile that fits the displays exactly, if one does
fn apply_best(quiet: bool) -> Result<(), String> {
    let list = profiles(&load());
    let connected = connected_keys()?;
    let Some(profile) = best(&list, &connected, true).cloned() else {
        return if quiet { Ok(()) } else { Err("no profile fits the displays connected".into()) };
    };
    apply(&profile)?;
    let name = profile["name"].as_str().unwrap_or_default().to_string();
    change(|store| {
        store.insert("last".into(), json!(name));
        Ok(())
    })?;
    let _ = Command::new("neko-notification-send")
        .args(["-u", "low", "-g", "󰍹", "Display profile", &name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    Ok(())
}

// ----------------------------------------------------------------- watcher

fn socket_path() -> Option<PathBuf> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    Some(PathBuf::from(runtime).join("hypr").join(signature).join(".socket2.sock"))
}

/// Applies the profile that fits each time the displays change, once they've
/// settled. Hyprland's event socket says when one comes or goes.
fn watch() -> Result<(), String> {
    let path = socket_path().ok_or("not inside a Hyprland session")?;
    let (tell, heard) = mpsc::channel::<()>();
    thread::spawn(move || {
        loop {
            if let Ok(stream) = UnixStream::connect(&path) {
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { break };
                    let event = line.split(">>").next().unwrap_or_default();
                    if matches!(event, "monitoradded" | "monitoraddedv2" | "monitorremoved" | "monitorremovedv2") {
                        let _ = tell.send(());
                    }
                }
            }
            // Hyprland restarting: try again in a moment
            thread::sleep(Duration::from_secs(2));
        }
    });
    let mut last: Vec<String> = Vec::new();
    loop {
        if heard.recv().is_err() {
            return Ok(());
        }
        // Wait until the events stop coming
        while heard.recv_timeout(SETTLE).is_ok() {}
        if load().get("auto").and_then(Value::as_bool) == Some(false) {
            continue;
        }
        let mut connected = connected_keys().unwrap_or_default();
        connected.sort();
        if connected.is_empty() || connected == last {
            continue;
        }
        last = connected;
        if let Err(error) = apply_best(true) {
            eprintln!("neko-display-profiles: {error}");
        }
    }
}

fn unit_active() -> bool {
    Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", &format!("{UNIT}.service")])
        .status()
        .is_ok_and(|status| status.success())
}

fn start() -> Result<(), String> {
    if unit_active() || load().get("auto").and_then(Value::as_bool) == Some(false) {
        return Ok(());
    }
    let program = std::env::current_exe().map_err(|error| format!("can't find neko-core: {error}"))?;
    let mut command = Command::new("systemd-run");
    command.args(["--user", "--quiet", &format!("--unit={UNIT}"), "--property=Restart=on-failure", "--property=RestartSec=10"]);
    for name in ["NEKO_PATH", "PATH", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
        if let Ok(value) = std::env::var(name) {
            command.arg(format!("--setenv={name}={value}"));
        }
    }
    let status = command
        .arg(program)
        .args(["display-profile", "watch"])
        .stdout(Stdio::null())
        .status()
        .map_err(|error| format!("can't run systemd-run: {error}"))?;
    if status.success() { Ok(()) } else { Err("systemd-run couldn't start the display-profile watcher".into()) }
}

fn stop() {
    let _ = Command::new("systemctl")
        .args(["--user", "stop", &format!("{UNIT}.service")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// ----------------------------------------------------------------- command

fn list() -> Result<Value, String> {
    let store = load();
    let list = profiles(&store);
    let all = monitors()?;
    let connected: Vec<String> = all.iter().filter(|monitor| monitor["name"].as_str() != Some("FALLBACK")).map(monitor_key).collect();
    let best_name = best(&list, &connected, true).and_then(|profile| profile["name"].as_str()).map(str::to_string);
    let entries: Vec<Value> = list
        .iter()
        .map(|profile| {
            let outputs = outputs_of(profile);
            let fit = fit(&outputs, &connected);
            let displays: Vec<Value> = outputs
                .iter()
                .map(|output| {
                    let builtin = is_builtin(output["name"].as_str().unwrap_or_default());
                    json!({
                        "description": output["description"],
                        "name": output["name"],
                        "enabled": output["enabled"],
                        "builtin": builtin,
                        "connected": connected.iter().any(|key| Some(key.as_str()) == output["key"].as_str()),
                        "settings": output["settings"],
                    })
                })
                .collect();
            json!({
                "name": profile["name"],
                "score": fit.score,
                "exact": fit.exact,
                "displays": displays,
            })
        })
        .collect();
    Ok(json!({
        "auto": store.get("auto").cloned().unwrap_or(json!(true)),
        "watching": unit_active(),
        "last": store.get("last").cloned().unwrap_or(Value::Null),
        "best": best_name,
        "profiles": entries,
    }))
}

pub fn run(args: &[String]) -> Result<(), String> {
    let Some((verb, rest)) = args.split_first() else {
        return Err("usage: neko-core display-profile <list|save|apply|apply-best|delete|rename|auto|start|stop|watch>".into());
    };
    let name = || rest.first().map(|name| name.as_str()).ok_or_else(|| "which profile?".to_string());
    match verb.as_str() {
        "list" => {
            println!("{}", serde_json::to_string(&list()?).map_err(|error| error.to_string())?);
            Ok(())
        }
        "save" => {
            let name = clean_name(name()?)?;
            let outputs = snapshot()?;
            if !outputs.iter().any(|output| output["enabled"].as_bool() == Some(true)) {
                return Err("no display is on".into());
            }
            let _lock = Lock::take()?;
            let mut store = load();
            let mut list: Vec<Value> = profiles(&store)
                .into_iter()
                .filter(|profile| !profile["name"].as_str().is_some_and(|other| other.eq_ignore_ascii_case(&name)))
                .collect();
            list.push(json!({ "name": name, "outputs": outputs }));
            store.insert("profiles".into(), Value::Array(list));
            store.insert("last".into(), json!(name));
            save_store(&store)
        }
        "apply" => apply_named(name()?),
        "apply-best" => apply_best(false),
        "delete" => {
            let name = name()?;
            let _lock = Lock::take()?;
            let mut store = load();
            let list = profiles(&store);
            if find(&list, name).is_none() {
                return Err(format!("no profile called {name}"));
            }
            let kept: Vec<Value> =
                list.into_iter().filter(|profile| !profile["name"].as_str().is_some_and(|other| other.eq_ignore_ascii_case(name))).collect();
            store.insert("profiles".into(), Value::Array(kept));
            if store.get("last").and_then(Value::as_str).is_some_and(|last| last.eq_ignore_ascii_case(name)) {
                store.remove("last");
            }
            save_store(&store)
        }
        "rename" => {
            let (old, new) = (name()?, clean_name(rest.get(1).ok_or("rename to what?")?)?);
            let _lock = Lock::take()?;
            let mut store = load();
            let mut list = profiles(&store);
            if !old.eq_ignore_ascii_case(&new) && find(&list, &new).is_some() {
                return Err(format!("there's already a profile called {new}"));
            }
            let profile = list
                .iter_mut()
                .find(|profile| profile["name"].as_str().is_some_and(|other| other.eq_ignore_ascii_case(old)))
                .ok_or_else(|| format!("no profile called {old}"))?;
            profile["name"] = json!(new);
            store.insert("profiles".into(), Value::Array(list));
            if store.get("last").and_then(Value::as_str).is_some_and(|last| last.eq_ignore_ascii_case(old)) {
                store.insert("last".into(), json!(new));
            }
            save_store(&store)
        }
        "auto" => {
            let on = match rest.first().map(String::as_str) {
                Some("on") => true,
                Some("off") => false,
                _ => return Err("auto takes on or off".into()),
            };
            change(|store| {
                store.insert("auto".into(), json!(on));
                Ok(())
            })?;
            if on {
                start()?;
                apply_best(true)
            } else {
                stop();
                Ok(())
            }
        }
        "start" => start(),
        "stop" => {
            stop();
            Ok(())
        }
        "watch" => watch(),
        other => Err(format!("unknown display-profile command: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(key: &str, enabled: bool) -> Value {
        json!({ "key": key, "name": key, "enabled": enabled, "settings": {} })
    }

    fn keys(list: &[&str]) -> Vec<String> {
        list.iter().map(|key| key.to_string()).collect()
    }

    #[test]
    fn keys_by_hardware() {
        assert_eq!(hardware_key("Acer  Technologies", "KA270 E", "1343", "", "HDMI-A-1"), "Acer Technologies|KA270 E|1343");
        assert_eq!(hardware_key("", "", "", "Some panel", "eDP-1"), "Some panel");
        assert_eq!(hardware_key("", "", "", "", "eDP-1"), "eDP-1");
    }

    #[test]
    fn an_exact_fit() {
        let profile = [output("laptop", false), output("desk", true)];
        assert_eq!(fit(&profile, &keys(&["laptop", "desk"])), Fit { score: 150, exact: true });
    }

    #[test]
    fn a_missing_display_or_a_stranger() {
        let profile = [output("laptop", true), output("desk", true)];
        // Undocked: the desk's display is missing
        assert_eq!(fit(&profile, &keys(&["laptop"])), Fit { score: 70, exact: false });
        // Somewhere else: a display the profile doesn't know
        assert_eq!(fit(&profile, &keys(&["laptop", "desk", "projector"])), Fit { score: 180, exact: false });
        // Nothing it turns on is here
        assert_eq!(fit(&profile, &keys(&["projector"])), Fit::default());
    }

    #[test]
    fn picks_the_exact_fit() {
        let docked = json!({ "name": "docked", "outputs": [output("laptop", false), output("desk", true)] });
        let mobile = json!({ "name": "mobile", "outputs": [output("laptop", true)] });
        let list = [docked, mobile];
        assert_eq!(best(&list, &keys(&["laptop", "desk"]), true).unwrap()["name"], "docked");
        assert_eq!(best(&list, &keys(&["laptop"]), true).unwrap()["name"], "mobile");
        assert!(best(&list, &keys(&["desk"]), true).is_none());
    }

    #[test]
    fn assigns_twins_to_their_own_connectors() {
        let outputs = [
            json!({ "key": "twin", "name": "DP-2", "enabled": true, "settings": {} }),
            json!({ "key": "twin", "name": "DP-1", "enabled": true, "settings": {} }),
        ];
        let monitors = [
            json!({ "name": "DP-1", "make": "twin" }),
            json!({ "name": "DP-2", "make": "twin" }),
        ];
        let pairs = assign(&outputs, &monitors);
        assert_eq!(pairs.len(), 2);
        assert!(pairs.iter().all(|(output, connector)| output["name"].as_str() == Some(connector.as_str())));
    }
}
