//! `neko-core clock`: timers, alarms and a stopwatch, kept in
//! ~/.local/state/neko/clock.json, which the shell watches and draws.
//!
//! Times are epoch milliseconds, never tick counts, so a timer comes out right
//! after a suspend or a shell restart. Nothing keeps running to watch them:
//! every change arms one transient systemd timer (neko-clock.timer) for the
//! next thing due, and that timer runs `clock fire`, which rings it (as a
//! unit of its own, neko-clock-ring). So an alarm rings whether or not the
//! shell is up, and a shell restart leaves no watcher behind.
//!
//!   state                         the state, as JSON
//!   timer-add <duration [label]> [label]
//!                                 "5" (minutes), "1:30", "1h 30m", "90s";
//!                                 "25 focus" names it too
//!   timer-pause|timer-resume|timer-restart|timer-remove <id>
//!   alarm-add <time [label]> [days] [label]
//!                                 "7:30", "19:30", "7pm", "7:30 work"; days
//!                                 as 0-6 (Sunday first), comma-separated, or
//!                                 none for once
//!   alarm-enable|alarm-disable|alarm-remove <id>
//!   stopwatch-toggle|stopwatch-lap|stopwatch-reset
//!   dismiss|snooze                what's ringing: quiet it, or again in 5 min
//!   schedule                      arm the timer for the next thing due
//!   fire                          ring what's due (the timer runs this)

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader};
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::{Datelike, Duration as Days, Local, LocalResult, TimeZone};
use serde_json::{Value, json};

/// Later than this, something due is "missed" and gets a quiet notice: the
/// machine was off or asleep, and nobody wants this morning's alarm at noon
const GRACE_MS: i64 = 15 * 60_000;
const SNOOZE_MS: i64 = 5 * 60_000;
const MAX_DURATION_MS: i64 = 100 * 3_600_000;
const MAX_ITEMS: usize = 20;
const MAX_LAPS: usize = 99;
const MAX_LABEL: usize = 40;
/// The sound repeats this long; the notification stays until it's answered
const SOUND_LIMIT: Duration = Duration::from_secs(60);
const SOUND_GAP: Duration = Duration::from_millis(800);
const UNIT: &str = "neko-clock";
const SOUND: &str = "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga";

// ---------------------------------------------------------------- the model

#[derive(Clone, Debug, PartialEq)]
struct Timer {
    id: String,
    label: String,
    duration_ms: i64,
    /// running, paused or done: a finished timer stays, one click from again
    state: String,
    ends_at: i64,
    remaining_ms: i64,
}

#[derive(Clone, Debug, PartialEq)]
struct Alarm {
    id: String,
    label: String,
    hour: u32,
    minute: u32,
    /// Weekdays it repeats on, 0 being Sunday; none rings once
    days: Vec<u32>,
    enabled: bool,
    snoozed: bool,
    next_fire: i64,
}

#[derive(Clone, Debug, PartialEq, Default)]
struct Stopwatch {
    running: bool,
    started_at: i64,
    accumulated_ms: i64,
    laps: Vec<i64>,
}

/// Something that fell due
#[derive(Clone, Debug, PartialEq)]
struct Event {
    kind: String,
    id: String,
    label: String,
    duration_ms: i64,
    hour: u32,
    minute: u32,
}

#[derive(Clone, Debug, PartialEq, Default)]
struct State {
    timers: Vec<Timer>,
    alarms: Vec<Alarm>,
    stopwatch: Stopwatch,
    ringing: Vec<Event>,
}

fn label_of(value: &str) -> String {
    value.trim().chars().take(MAX_LABEL).collect()
}

fn count(value: Option<&Value>) -> Option<i64> {
    value.and_then(Value::as_i64).filter(|value| *value >= 0)
}

fn text(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or("").to_string()
}

fn valid_days(value: Option<&Value>) -> Vec<u32> {
    let mut days: Vec<u32> = value
        .and_then(Value::as_array)
        .map(|days| days.iter().filter_map(Value::as_u64).filter(|day| *day <= 6).map(|day| day as u32).collect())
        .unwrap_or_default();
    days.sort_unstable();
    days.dedup();
    days
}

fn event_from(value: &Value) -> Option<Event> {
    let kind = text(value.get("kind"));
    let id = text(value.get("id"));
    if (kind != "timer" && kind != "alarm") || id.is_empty() {
        return None;
    }
    Some(Event {
        kind,
        id,
        label: label_of(&text(value.get("label"))),
        duration_ms: count(value.get("durationMs")).unwrap_or(0),
        hour: count(value.get("hour")).unwrap_or(0) as u32,
        minute: count(value.get("minute")).unwrap_or(0) as u32,
    })
}

/// The state file is hand-editable, so nothing in it is trusted to have the
/// right shape: an entry that makes no sense is dropped
fn state_from(raw: &Value, now: i64) -> State {
    let mut state = State::default();
    if let Some(timers) = raw.get("timers").and_then(Value::as_array) {
        state.timers = timers
            .iter()
            .filter_map(|timer| {
                let id = text(timer.get("id"));
                let duration_ms = count(timer.get("durationMs")).filter(|ms| *ms > 0)?;
                let status = text(timer.get("state"));
                if id.is_empty() || !["running", "paused", "done"].contains(&status.as_str()) {
                    return None;
                }
                Some(Timer {
                    id,
                    label: label_of(&text(timer.get("label"))),
                    duration_ms,
                    state: status,
                    ends_at: count(timer.get("endsAt")).unwrap_or(0),
                    remaining_ms: count(timer.get("remainingMs")).unwrap_or(0),
                })
            })
            .take(MAX_ITEMS)
            .collect();
    }
    if let Some(alarms) = raw.get("alarms").and_then(Value::as_array) {
        state.alarms = alarms
            .iter()
            .filter_map(|alarm| {
                let id = text(alarm.get("id"));
                let hour = count(alarm.get("hour")).filter(|hour| *hour <= 23)? as u32;
                let minute = count(alarm.get("minute")).filter(|minute| *minute <= 59)? as u32;
                if id.is_empty() {
                    return None;
                }
                let days = valid_days(alarm.get("days"));
                let enabled = alarm.get("enabled").and_then(Value::as_bool) == Some(true);
                let next_fire = match count(alarm.get("nextFire")) {
                    _ if !enabled => 0,
                    Some(next) if next > 0 => next,
                    _ => next_alarm_fire(hour, minute, &days, now),
                };
                Some(Alarm {
                    id,
                    label: label_of(&text(alarm.get("label"))),
                    hour,
                    minute,
                    days,
                    enabled,
                    snoozed: enabled && alarm.get("snoozed").and_then(Value::as_bool) == Some(true),
                    next_fire,
                })
            })
            .take(MAX_ITEMS)
            .collect();
    }
    if let Some(watch) = raw.get("stopwatch") {
        if let Some(accumulated_ms) = count(watch.get("accumulatedMs")) {
            let started_at = count(watch.get("startedAt")).unwrap_or(0);
            let running = watch.get("running").and_then(Value::as_bool) == Some(true) && started_at > 0;
            state.stopwatch = Stopwatch {
                running,
                started_at: if running { started_at } else { 0 },
                accumulated_ms,
                laps: watch
                    .get("laps")
                    .and_then(Value::as_array)
                    .map(|laps| laps.iter().filter_map(|lap| count(Some(lap))).take(MAX_LAPS).collect())
                    .unwrap_or_default(),
            };
        }
    }
    if let Some(ringing) = raw.get("ringing").and_then(Value::as_array) {
        state.ringing = ringing.iter().filter_map(event_from).collect();
    }
    state
}

fn event_json(event: &Event) -> Value {
    json!({
        "kind": event.kind,
        "id": event.id,
        "label": event.label,
        "durationMs": event.duration_ms,
        "hour": event.hour,
        "minute": event.minute,
    })
}

fn state_json(state: &State) -> Value {
    json!({
        "timers": state.timers.iter().map(|timer| json!({
            "id": timer.id,
            "label": timer.label,
            "durationMs": timer.duration_ms,
            "state": timer.state,
            "endsAt": timer.ends_at,
            "remainingMs": timer.remaining_ms,
        })).collect::<Vec<_>>(),
        "alarms": state.alarms.iter().map(|alarm| json!({
            "id": alarm.id,
            "label": alarm.label,
            "hour": alarm.hour,
            "minute": alarm.minute,
            "days": alarm.days,
            "enabled": alarm.enabled,
            "snoozed": alarm.snoozed,
            "nextFire": alarm.next_fire,
        })).collect::<Vec<_>>(),
        "stopwatch": {
            "running": state.stopwatch.running,
            "startedAt": state.stopwatch.started_at,
            "accumulatedMs": state.stopwatch.accumulated_ms,
            "laps": state.stopwatch.laps,
        },
        "ringing": state.ringing.iter().map(event_json).collect::<Vec<_>>(),
    })
}

// --------------------------------------------------------------- parsing

/// Digits, then the rest
fn split_number(text: &str) -> Option<(u64, &str)> {
    let end = text.find(|c: char| !c.is_ascii_digit()).unwrap_or(text.len());
    if end == 0 {
        return None;
    }
    Some((text[..end].parse().ok()?, &text[end..]))
}

/// "5" and "1.5" are minutes, the unit a kitchen timer speaks. "1:30" is
/// minutes and seconds, "1:02:03" adds hours, and "1h 30m", "90s", "2 min"
/// name their own. None for anything unreadable or out of range.
fn parse_duration(input: &str) -> Option<i64> {
    let value = input.trim().to_lowercase().replace(',', ".");
    if value.is_empty() {
        return None;
    }
    let ms = if value.chars().all(|c| c.is_ascii_digit() || c == '.') {
        if value.matches('.').count() > 1 || value.starts_with('.') || value.ends_with('.') {
            return None;
        }
        (value.parse::<f64>().ok()? * 60_000.0).round() as i64
    } else if value.contains(':') {
        let parts: Vec<&str> = value.split(':').collect();
        if parts.len() > 3 || parts.iter().any(|part| part.is_empty() || !part.chars().all(|c| c.is_ascii_digit())) {
            return None;
        }
        let numbers: Vec<i64> = parts.iter().map(|part| part.parse().unwrap_or(0)).collect();
        let seconds = *numbers.last()?;
        if seconds > 59 || parts.last()?.len() > 2 {
            return None;
        }
        let (hours, minutes) = if numbers.len() == 3 { (numbers[0], numbers[1]) } else { (0, numbers[0]) };
        (hours * 3600 + minutes * 60 + seconds) * 1000
    } else {
        // Units in order, hours then minutes then seconds, each at most once
        let mut rest = value.as_str();
        let mut total = 0i64;
        let mut last_rank = 0;
        while !rest.trim_start().is_empty() {
            let (number, after) = split_number(rest.trim_start())?;
            let after = after.trim_start();
            let unit_end = after.find(|c: char| !c.is_ascii_alphabetic()).unwrap_or(after.len());
            let (unit, next) = after.split_at(unit_end);
            let (rank, scale) = match unit {
                "h" | "hr" | "hrs" | "hour" | "hours" => (1, 3600),
                "m" | "min" | "mins" | "minute" | "minutes" => (2, 60),
                "s" | "sec" | "secs" | "second" | "seconds" => (3, 1),
                _ => return None,
            };
            if rank <= last_rank {
                return None;
            }
            last_rank = rank;
            total += number as i64 * scale;
            rest = next;
        }
        total * 1000
    };
    (ms > 0 && ms <= MAX_DURATION_MS).then_some(ms)
}

/// "7", "7:30", "730", "19:30", "1930", "7pm", "7:30 a.m.". None if unreadable.
fn parse_alarm_time(input: &str) -> Option<(u32, u32)> {
    let value = input.trim().to_lowercase();
    let digits_end = value.find(|c: char| !c.is_ascii_digit() && c != ':').unwrap_or(value.len());
    let (clock, suffix) = value.split_at(digits_end);
    let meridiem = match suffix.trim().replace('.', "").as_str() {
        "" => None,
        "a" | "am" => Some(false),
        "p" | "pm" => Some(true),
        _ => return None,
    };
    let (hour_text, minute_text) = match clock.split_once(':') {
        Some((hour, minute)) => (hour, minute),
        None if clock.len() > 2 => clock.split_at(clock.len() - 2),
        None => (clock, ""),
    };
    if hour_text.is_empty() || hour_text.len() > 2 || (!minute_text.is_empty() && minute_text.len() != 2) {
        return None;
    }
    if minute_text.contains(':') {
        return None;
    }
    let mut hour: u32 = hour_text.parse().ok()?;
    let minute: u32 = if minute_text.is_empty() { 0 } else { minute_text.parse().ok()? };
    if minute > 59 {
        return None;
    }
    match meridiem {
        Some(pm) => {
            if !(1..=12).contains(&hour) {
                return None;
            }
            hour = hour % 12 + if pm { 12 } else { 0 };
        }
        None if hour > 23 => return None,
        None => {}
    }
    Some((hour, minute))
}

/// What people type in one go, "25 focus" or "1h 30m laundry": the longest run
/// of leading words `parse` reads, and the rest as the label
fn split_leading<T>(input: &str, parse: impl Fn(&str) -> Option<T>) -> Option<(T, String)> {
    let words: Vec<&str> = input.split_whitespace().collect();
    (1..=words.len()).rev().find_map(|count| {
        let value = parse(&words[..count].join(" "))?;
        Some((value, words[count..].join(" ")))
    })
}

/// "1,3,5" as weekdays, Sunday being 0
fn parse_days(input: &str) -> Result<Vec<u32>, String> {
    let mut days = Vec::new();
    for part in input.split(',').map(str::trim).filter(|part| !part.is_empty()) {
        let day: u32 = part.parse().map_err(|_| format!("not a weekday: {part}"))?;
        if day > 6 {
            return Err(format!("not a weekday: {part} (0 is Sunday, 6 Saturday)"));
        }
        days.push(day);
    }
    days.sort_unstable();
    days.dedup();
    Ok(days)
}

// ------------------------------------------------------------------ time

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_millis() as i64).unwrap_or(0)
}

/// The next time an alarm rings after `after`, in local time on purpose: 7:30
/// stays 7:30 across a daylight-saving change. Eight days cover a weekly
/// alarm whose only day is today but whose time has passed.
fn next_alarm_fire(hour: u32, minute: u32, days: &[u32], after: i64) -> i64 {
    let Some(base) = Local.timestamp_millis_opt(after).single() else {
        return 0;
    };
    for offset in 0..=8 {
        let date = base.date_naive() + Days::days(offset);
        let Some(naive) = date.and_hms_opt(hour, minute, 0) else {
            continue;
        };
        // A time the clocks skip rings an hour on; a time they repeat, the first
        let candidate = match Local.from_local_datetime(&naive) {
            LocalResult::Single(time) | LocalResult::Ambiguous(time, _) => time,
            LocalResult::None => match Local.from_local_datetime(&(naive + chrono::Duration::hours(1))) {
                LocalResult::Single(time) | LocalResult::Ambiguous(time, _) => time,
                LocalResult::None => continue,
            },
        };
        let at = candidate.timestamp_millis();
        if at <= after {
            continue;
        }
        if days.is_empty() || days.contains(&candidate.weekday().num_days_from_sunday()) {
            return at;
        }
    }
    0
}

fn timer_remaining(timer: &Timer, now: i64) -> i64 {
    match timer.state.as_str() {
        "running" => (timer.ends_at - now).max(0),
        "paused" => timer.remaining_ms,
        _ => 0,
    }
}

fn stopwatch_elapsed(watch: &Stopwatch, now: i64) -> i64 {
    watch.accumulated_ms + if watch.running { (now - watch.started_at).max(0) } else { 0 }
}

/// Moves everything due at `now` on and reports what fell due, and what was
/// missed (more than GRACE_MS late)
fn advance(state: &mut State, now: i64) -> (Vec<Event>, Vec<Event>) {
    let mut due = Vec::new();
    let mut missed = Vec::new();
    let mut report = |event: Event, at: i64| {
        if now - at > GRACE_MS { missed.push(event) } else { due.push(event) }
    };
    for timer in &mut state.timers {
        if timer.state != "running" || timer.ends_at > now {
            continue;
        }
        report(
            Event {
                kind: "timer".into(),
                id: timer.id.clone(),
                label: timer.label.clone(),
                duration_ms: timer.duration_ms,
                hour: 0,
                minute: 0,
            },
            timer.ends_at,
        );
        timer.state = "done".into();
        timer.ends_at = 0;
        timer.remaining_ms = 0;
    }
    for alarm in &mut state.alarms {
        if !alarm.enabled || alarm.next_fire == 0 || alarm.next_fire > now {
            continue;
        }
        report(
            Event {
                kind: "alarm".into(),
                id: alarm.id.clone(),
                label: alarm.label.clone(),
                duration_ms: 0,
                hour: alarm.hour,
                minute: alarm.minute,
            },
            alarm.next_fire,
        );
        let repeats = !alarm.days.is_empty();
        alarm.enabled = repeats;
        alarm.snoozed = false;
        alarm.next_fire = if repeats { next_alarm_fire(alarm.hour, alarm.minute, &alarm.days, now) } else { 0 };
    }
    (due, missed)
}

/// Brings whatever just rang back in five minutes
fn snooze(state: &mut State, now: i64) {
    let at = now + SNOOZE_MS;
    let rang = |kind: &str, id: &str| state.ringing.iter().any(|event| event.kind == kind && event.id == id);
    let rang_timers: Vec<bool> = state.timers.iter().map(|timer| rang("timer", &timer.id)).collect();
    let rang_alarms: Vec<bool> = state.alarms.iter().map(|alarm| rang("alarm", &alarm.id)).collect();
    for (timer, rang) in state.timers.iter_mut().zip(rang_timers) {
        if rang {
            timer.state = "running".into();
            timer.ends_at = at;
            timer.remaining_ms = SNOOZE_MS;
        }
    }
    for (alarm, rang) in state.alarms.iter_mut().zip(rang_alarms) {
        if rang {
            alarm.enabled = true;
            alarm.snoozed = true;
            alarm.next_fire = at;
        }
    }
    state.ringing.clear();
}

/// When the next thing falls due, if anything will
fn next_due(state: &State) -> Option<i64> {
    let timers = state.timers.iter().filter(|timer| timer.state == "running").map(|timer| timer.ends_at);
    let alarms = state.alarms.iter().filter(|alarm| alarm.enabled && alarm.next_fire > 0).map(|alarm| alarm.next_fire);
    timers.chain(alarms).min()
}

fn format_countdown(ms: i64) -> String {
    let total = (ms.max(0) + 999) / 1000;
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    if hours > 0 { format!("{hours}:{minutes:02}:{seconds:02}") } else { format!("{minutes}:{seconds:02}") }
}

fn make_id(now: i64) -> String {
    let mut value = now as u64 ^ (std::process::id() as u64) << 20;
    let mut id = String::new();
    while value > 0 {
        id.insert(0, char::from_digit((value % 36) as u32, 36).unwrap_or('0'));
        value /= 36;
    }
    id
}

// --------------------------------------------------------------- storage

fn state_dir() -> PathBuf {
    let base = std::env::var("XDG_STATE_HOME")
        .ok()
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("neko")
}

/// Held while the state is read, changed and written: the shell, the timer
/// and the ringing process can all reach for it at once. The lock lasts as
/// long as the file is open.
struct Lock(#[allow(dead_code)] File);

impl Lock {
    fn take() -> Result<Lock, String> {
        let dir = state_dir();
        fs::create_dir_all(&dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(dir.join("clock.lock"))
            .map_err(|error| format!("can't open the clock's lock: {error}"))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err("can't lock the clock's state".into());
        }
        Ok(Lock(file))
    }
}

fn load(now: i64) -> State {
    fs::read_to_string(state_dir().join("clock.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .map(|raw| state_from(&raw, now))
        .unwrap_or_default()
}

/// Written whole and moved into place, so a reader never sees half of it
fn save(state: &State) -> Result<(), String> {
    let dir = state_dir();
    let path = dir.join("clock.json");
    let temp = dir.join(".clock.json.new");
    let text = serde_json::to_string_pretty(&state_json(state)).map_err(|error| error.to_string())? + "\n";
    fs::write(&temp, text).map_err(|error| format!("can't write {}: {error}", temp.display()))?;
    fs::rename(&temp, &path).map_err(|error| format!("can't write {}: {error}", path.display()))
}

// ---------------------------------------------------------- the timer unit

/// Arms neko-clock.timer for the next thing due, or stops it with nothing due.
/// A realtime timer, so it fires on time after a suspend; one passed while
/// asleep fires on waking, and `fire` sorts due from missed.
fn schedule(state: &State) -> Result<(), String> {
    let _ = Command::new("systemctl")
        .args(["--user", "stop", &format!("{UNIT}.timer")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let Some(due) = next_due(state) else {
        return Ok(());
    };
    // The second it's due in, rounded up so it's never early
    let at = Local
        .timestamp_millis_opt(due + 999)
        .single()
        .ok_or("the next time due is out of range")?
        .format("%Y-%m-%d %H:%M:%S")
        .to_string();
    let status = transient_unit(UNIT, &[&format!("--on-calendar={at}"), "--timer-property=AccuracySec=1s"], "fire")?
        .status()
        .map_err(|error| format!("can't run systemd-run: {error}"))?;
    if status.success() { Ok(()) } else { Err("systemd-run couldn't arm the clock's timer".into()) }
}

/// systemd-run for one of the clock's own transient units, running `clock
/// <verb>` with what it needs to reach the desktop and the shell
fn transient_unit(unit: &str, options: &[&str], verb: &str) -> Result<Command, String> {
    let program = std::env::current_exe().map_err(|error| format!("can't find neko-core: {error}"))?;
    let mut command = Command::new("systemd-run");
    command.args(["--user", "--quiet", &format!("--unit={unit}")]).args(options);
    for name in [
        "NEKO_PATH",
        "PATH",
        "NEKO_QUICKSHELL",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "DBUS_SESSION_BUS_ADDRESS",
    ] {
        if let Ok(value) = std::env::var(name) {
            command.arg(format!("--setenv={name}={value}"));
        }
    }
    command.arg(program).args(["clock", verb]).stdout(Stdio::null()).stderr(Stdio::null());
    Ok(command)
}

// --------------------------------------------------------------- ringing

fn headline(event: &Event, missed: bool) -> String {
    let what = if event.kind == "timer" { "Timer" } else { "Alarm" };
    let verb = if missed { "missed" } else if event.kind == "timer" { "done" } else { "ringing" };
    if event.label.is_empty() { format!("{what} {verb}") } else { format!("{what} {verb}: {}", event.label) }
}

fn body(event: &Event) -> String {
    if event.kind == "timer" {
        format_countdown(event.duration_ms)
    } else {
        format!("{}:{:02}", event.hour, event.minute)
    }
}

fn notify_missed(event: &Event) {
    let _ = Command::new("notify-send")
        .args(["-a", "Clock", "-u", "normal", "-i", "alarm-symbolic", &headline(event, true), &body(event)])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// The ringing runs as a unit of its own: systemd ends whatever a finished
/// unit leaves running, so it can't be a child of the timer's run, and
/// stopping it ends its sound and notification with it
const RING_UNIT: &str = "neko-clock-ring";

/// Ends the ringing, its sound and its notification, if it's up
fn stop_ringing(events: &[Event]) {
    // Not from the ringing itself, which is on its way out
    if std::env::var("NEKO_CLOCK_RINGING").is_err() {
        let _ = Command::new("systemctl")
            .args(["--user", "stop", &format!("{RING_UNIT}.service")])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    for event in events {
        let _ = Command::new("neko-shell")
            .args(["-q", "notifications", "dismiss", &headline(event, false)])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn start_ringing() -> Result<(), String> {
    let status = transient_unit(RING_UNIT, &["--collect", "--setenv=NEKO_CLOCK_RINGING=1"], "ring")?
        .status()
        .map_err(|error| format!("can't run systemd-run: {error}"))?;
    if status.success() { Ok(()) } else { Err("systemd-run couldn't start the ringing".into()) }
}

/// The ringing process: a notification to answer, and the sound until it's
/// answered or a minute has passed. The notification's answer dismisses or
/// snoozes.
fn ring() -> Result<(), String> {
    let events = {
        let _lock = Lock::take()?;
        load(now_ms()).ringing
    };
    let Some(first) = events.first() else {
        return Ok(());
    };

    let summary = if events.len() > 1 {
        format!("{} (and {} more)", headline(first, false), events.len() - 1)
    } else {
        headline(first, false)
    };
    let mut notification = Command::new("notify-send")
        .args([
            "-a",
            "Clock",
            "-u",
            "critical",
            "-i",
            "alarm-symbolic",
            "-A",
            "dismiss=Dismiss",
            "-A",
            "snooze=Snooze 5 min",
            "--wait",
            &summary,
            &body(first),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("can't show the notification: {error}"))?;
    let answer = notification.stdout.take();
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        if let Some(out) = answer {
            let _ = BufReader::new(out).read_line(&mut line);
        }
        let _ = sender.send(line.trim().to_string());
    });

    let player = ["pw-play", "paplay"].into_iter().find(|player| {
        Command::new("sh").args(["-c", &format!("command -v {player}")]).stdout(Stdio::null()).status().is_ok_and(|s| s.success())
    });
    let started = Instant::now();
    let answer = loop {
        if let Ok(answer) = receiver.try_recv() {
            break answer;
        }
        if started.elapsed() < SOUND_LIMIT && std::path::Path::new(SOUND).exists() {
            if let Some(player) = player {
                let _ = Command::new(player).arg(SOUND).stdout(Stdio::null()).stderr(Stdio::null()).status();
            }
            sleep(SOUND_GAP);
        } else {
            // Quiet now; the notification stays until it's answered
            break receiver.recv().unwrap_or_default();
        }
    };
    let _ = notification.wait();

    let _lock = Lock::take()?;
    let now = now_ms();
    let mut state = load(now);
    // Answered already from the shell, or by a newer ringing
    if state.ringing != events {
        return Ok(());
    }
    if answer == "snooze" {
        snooze(&mut state, now);
    } else {
        state.ringing.clear();
    }
    save(&state)?;
    schedule(&state)
}

// ---------------------------------------------------------------- commands

fn find_timer<'a>(state: &'a mut State, id: &str) -> Result<&'a mut Timer, String> {
    state.timers.iter_mut().find(|timer| timer.id == id).ok_or_else(|| format!("no timer {id}"))
}

fn find_alarm<'a>(state: &'a mut State, id: &str) -> Result<&'a mut Alarm, String> {
    state.alarms.iter_mut().find(|alarm| alarm.id == id).ok_or_else(|| format!("no alarm {id}"))
}

fn arg(args: &[String], index: usize, what: &str) -> Result<String, String> {
    args.get(index).cloned().ok_or_else(|| format!("missing {what}"))
}

/// A removed item has nothing left to ring for
fn forget(state: &mut State, kind: &str, id: &str) {
    let before = state.ringing.clone();
    state.ringing.retain(|event| !(event.kind == kind && event.id == id));
    if state.ringing.is_empty() && !before.is_empty() {
        stop_ringing(&before);
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    let Some((verb, rest)) = args.split_first() else {
        return Err("usage: neko-core clock <state|timer-add|alarm-add|stopwatch-toggle|dismiss|snooze|schedule|fire|...>".into());
    };
    if verb == "ring" {
        return ring();
    }

    let lock = Lock::take()?;
    let now = now_ms();
    let mut state = load(now);
    // Whatever's already due rings before anything else changes
    let (due, missed) = advance(&mut state, now);
    match verb.as_str() {
        "state" => {
            println!("{}", serde_json::to_string(&state_json(&state)).map_err(|error| error.to_string())?);
        }
        "timer-add" => {
            let input = arg(rest, 0, "a duration")?;
            let (duration_ms, named) =
                split_leading(&input, parse_duration).ok_or_else(|| format!("can't read \"{input}\" as a duration"))?;
            if state.timers.len() >= MAX_ITEMS {
                return Err(format!("at most {MAX_ITEMS} timers"));
            }
            let id = make_id(now);
            state.timers.insert(
                0,
                Timer {
                    id: id.clone(),
                    label: label_of(&[named].into_iter().chain(rest.get(1..).unwrap_or_default().iter().cloned()).collect::<Vec<_>>().join(" ")),
                    duration_ms,
                    state: "running".into(),
                    ends_at: now + duration_ms,
                    remaining_ms: duration_ms,
                },
            );
            println!("{id}");
        }
        "timer-pause" => {
            let timer = find_timer(&mut state, &arg(rest, 0, "a timer")?)?;
            if timer.state == "running" {
                timer.remaining_ms = timer_remaining(timer, now);
                timer.state = "paused".into();
                timer.ends_at = 0;
            }
        }
        "timer-resume" => {
            let timer = find_timer(&mut state, &arg(rest, 0, "a timer")?)?;
            if timer.state == "paused" {
                timer.state = "running".into();
                timer.ends_at = now + timer.remaining_ms;
            }
        }
        "timer-restart" => {
            let id = arg(rest, 0, "a timer")?;
            forget(&mut state, "timer", &id);
            let timer = find_timer(&mut state, &id)?;
            timer.state = "running".into();
            timer.ends_at = now + timer.duration_ms;
            timer.remaining_ms = timer.duration_ms;
        }
        "timer-remove" => {
            let id = arg(rest, 0, "a timer")?;
            forget(&mut state, "timer", &id);
            state.timers.retain(|timer| timer.id != id);
        }
        "alarm-add" => {
            let input = arg(rest, 0, "a time")?;
            let ((hour, minute), named) =
                split_leading(&input, parse_alarm_time).ok_or_else(|| format!("can't read \"{input}\" as a time"))?;
            let days = parse_days(rest.get(1).map(String::as_str).unwrap_or(""))?;
            if state.alarms.len() >= MAX_ITEMS {
                return Err(format!("at most {MAX_ITEMS} alarms"));
            }
            let id = make_id(now);
            let next_fire = next_alarm_fire(hour, minute, &days, now);
            state.alarms.push(Alarm {
                id: id.clone(),
                label: label_of(&[named].into_iter().chain(rest.get(2..).unwrap_or_default().iter().cloned()).collect::<Vec<_>>().join(" ")),
                hour,
                minute,
                days,
                enabled: true,
                snoozed: false,
                next_fire,
            });
            println!("{id}");
        }
        "alarm-enable" | "alarm-disable" => {
            let enabled = verb == "alarm-enable";
            let alarm = find_alarm(&mut state, &arg(rest, 0, "an alarm")?)?;
            alarm.enabled = enabled;
            alarm.snoozed = false;
            alarm.next_fire = if enabled { next_alarm_fire(alarm.hour, alarm.minute, &alarm.days, now) } else { 0 };
        }
        "alarm-remove" => {
            let id = arg(rest, 0, "an alarm")?;
            forget(&mut state, "alarm", &id);
            state.alarms.retain(|alarm| alarm.id != id);
        }
        "stopwatch-toggle" => {
            let watch = &mut state.stopwatch;
            if watch.running {
                watch.accumulated_ms = stopwatch_elapsed(watch, now);
                watch.running = false;
                watch.started_at = 0;
            } else {
                watch.running = true;
                watch.started_at = now;
            }
        }
        "stopwatch-lap" => {
            let elapsed = stopwatch_elapsed(&state.stopwatch, now);
            let watch = &mut state.stopwatch;
            if watch.running && watch.laps.len() < MAX_LAPS {
                watch.laps.push(elapsed);
            }
        }
        "stopwatch-reset" => state.stopwatch = Stopwatch::default(),
        "dismiss" => {
            let events = std::mem::take(&mut state.ringing);
            stop_ringing(&events);
        }
        "snooze" => {
            let events = state.ringing.clone();
            snooze(&mut state, now);
            stop_ringing(&events);
        }
        "schedule" | "fire" => {}
        other => return Err(format!("unknown clock command: {other}")),
    }

    for event in &missed {
        notify_missed(event);
    }
    let rings = !due.is_empty();
    if rings {
        // A new ring replaces one still going, and takes its place
        let still = std::mem::take(&mut state.ringing);
        stop_ringing(&still);
        state.ringing = still.into_iter().chain(due).collect();
    }
    save(&state)?;
    schedule(&state)?;
    drop(lock);
    if rings {
        start_ringing()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Timelike;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("5"), Some(300_000));
        assert_eq!(parse_duration("1.5"), Some(90_000));
        assert_eq!(parse_duration("1,5"), Some(90_000));
        assert_eq!(parse_duration("1:30"), Some(90_000));
        assert_eq!(parse_duration("1:02:03"), Some(3_723_000));
        assert_eq!(parse_duration("1h 30m"), Some(5_400_000));
        assert_eq!(parse_duration("90s"), Some(90_000));
        assert_eq!(parse_duration("2 min"), Some(120_000));
        assert_eq!(parse_duration("1h30m15s"), Some(5_415_000));
        assert_eq!(parse_duration("1:60"), None);
        assert_eq!(parse_duration("30m 1h"), None);
        assert_eq!(parse_duration("0"), None);
        assert_eq!(parse_duration("101h"), None);
        assert_eq!(parse_duration("soon"), None);
        assert_eq!(parse_duration(""), None);
    }

    #[test]
    fn a_label_after_the_time() {
        assert_eq!(split_leading("25 focus", parse_duration), Some((1_500_000, "focus".into())));
        assert_eq!(split_leading("1h 30m laundry day", parse_duration), Some((5_400_000, "laundry day".into())));
        assert_eq!(split_leading("10", parse_duration), Some((600_000, String::new())));
        assert_eq!(split_leading("7:30 pm work", parse_alarm_time), Some(((19, 30), "work".into())));
        assert_eq!(split_leading("tea 5", parse_duration), None);
        assert_eq!(split_leading("", parse_duration), None);
    }

    #[test]
    fn alarm_times() {
        assert_eq!(parse_alarm_time("7"), Some((7, 0)));
        assert_eq!(parse_alarm_time("7:30"), Some((7, 30)));
        assert_eq!(parse_alarm_time("730"), Some((7, 30)));
        assert_eq!(parse_alarm_time("19:30"), Some((19, 30)));
        assert_eq!(parse_alarm_time("1930"), Some((19, 30)));
        assert_eq!(parse_alarm_time("7pm"), Some((19, 0)));
        assert_eq!(parse_alarm_time("12am"), Some((0, 0)));
        assert_eq!(parse_alarm_time("12 p.m."), Some((12, 0)));
        assert_eq!(parse_alarm_time("7:30 a.m."), Some((7, 30)));
        assert_eq!(parse_alarm_time("24:00"), None);
        assert_eq!(parse_alarm_time("13pm"), None);
        assert_eq!(parse_alarm_time("7:60"), None);
        assert_eq!(parse_alarm_time("later"), None);
    }

    #[test]
    fn alarms_land_on_their_days() {
        let monday_noon = Local.with_ymd_and_hms(2026, 11, 2, 12, 0, 0).unwrap().timestamp_millis();
        // Later today
        let today = next_alarm_fire(18, 0, &[], monday_noon);
        assert_eq!(Local.timestamp_millis_opt(today).unwrap().hour(), 18);
        assert_eq!(Local.timestamp_millis_opt(today).unwrap().day(), 2);
        // Passed today: tomorrow
        let tomorrow = next_alarm_fire(7, 0, &[], monday_noon);
        assert_eq!(Local.timestamp_millis_opt(tomorrow).unwrap().day(), 3);
        // Only Mondays, and today's has passed: next Monday
        let weekly = next_alarm_fire(7, 0, &[1], monday_noon);
        assert_eq!(Local.timestamp_millis_opt(weekly).unwrap().day(), 9);
        // Weekends
        let weekend = next_alarm_fire(9, 0, &[0, 6], monday_noon);
        assert_eq!(Local.timestamp_millis_opt(weekend).unwrap().weekday().num_days_from_sunday(), 6);
    }

    fn timer(id: &str, ends_at: i64) -> Timer {
        Timer {
            id: id.into(),
            label: String::new(),
            duration_ms: 60_000,
            state: "running".into(),
            ends_at,
            remaining_ms: 60_000,
        }
    }

    #[test]
    fn due_and_missed() {
        let now = 10_000_000;
        let mut state = State {
            timers: vec![timer("soon", now + 1), timer("now", now - 1000), timer("long", now - GRACE_MS - 1)],
            ..State::default()
        };
        let (due, missed) = advance(&mut state, now);
        assert_eq!(due.iter().map(|event| event.id.as_str()).collect::<Vec<_>>(), ["now"]);
        assert_eq!(missed.iter().map(|event| event.id.as_str()).collect::<Vec<_>>(), ["long"]);
        assert_eq!(state.timers[0].state, "running");
        assert_eq!(state.timers[1].state, "done");
        assert_eq!(next_due(&state), Some(now + 1));
    }

    #[test]
    fn snoozing_brings_it_back() {
        let now = 10_000_000;
        let mut state = State { timers: vec![timer("tea", now - 10)], ..State::default() };
        let (due, _) = advance(&mut state, now);
        state.ringing = due;
        snooze(&mut state, now);
        assert!(state.ringing.is_empty());
        assert_eq!(state.timers[0].state, "running");
        assert_eq!(state.timers[0].ends_at, now + SNOOZE_MS);
    }

    #[test]
    fn a_hand_edited_file_is_cleaned() {
        let raw = json!({
            "timers": [
                { "id": "ok", "durationMs": 1000, "state": "paused", "remainingMs": 500 },
                { "id": "", "durationMs": 1000, "state": "running" },
                { "id": "bad", "durationMs": -5, "state": "running" },
                { "id": "odd", "durationMs": 1000, "state": "exploded" }
            ],
            "alarms": [
                { "id": "a", "hour": 7, "minute": 0, "days": [1, 1, 9, 3], "enabled": true },
                { "id": "b", "hour": 25, "minute": 0 }
            ],
            "stopwatch": { "running": true, "startedAt": 0, "accumulatedMs": 5 }
        });
        let state = state_from(&raw, 10_000_000);
        assert_eq!(state.timers.len(), 1);
        assert_eq!(state.alarms.len(), 1);
        assert_eq!(state.alarms[0].days, [1, 3]);
        assert!(state.alarms[0].next_fire > 0);
        assert!(!state.stopwatch.running);
    }

    #[test]
    fn countdowns() {
        assert_eq!(format_countdown(300_000), "5:00");
        assert_eq!(format_countdown(299_001), "5:00");
        assert_eq!(format_countdown(3_723_000), "1:02:03");
        assert_eq!(format_countdown(0), "0:00");
    }
}
