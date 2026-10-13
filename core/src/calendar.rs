//! `neko-core calendar-events`: the events of the calendars in
//! ~/.config/neko/calendars between two days, as JSON, for the control
//! center's calendar.
//!
//! ~/.config/neko/calendars lists one feed per line: a URL (like Google
//! Calendar's "secret address in iCal format") or a local .ics file,
//! optionally after a name ("Work https://..."); # starts a comment. Feeds are
//! cached under ~/.cache/neko/calendars (readable only by you) and fetched
//! again once they're 15 minutes old.
//!
//! It prints a line of JSON from the cache at once, then, if a feed was
//! stale, another once it has been fetched:
//!
//!   {"configured": true, "days": {"2026-10-08": [{"title", "calendar",
//!    "allDay", "start", "end", "location"}]}, "errors": []}
//!
//! start and end are local "HH:MM" (empty for all-day events). Repeating
//! events follow the whole of RFC 5545's RRULE (the rrule crate), with their
//! exceptions (EXDATE) and moved instances (RECURRENCE-ID).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::{Duration as StdDuration, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone};
use rrule::{RRule, Tz, Unvalidated};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const STALE: StdDuration = StdDuration::from_secs(15 * 60);

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn cache_dir() -> PathBuf {
    home().join(".cache/neko/calendars")
}

fn is_url(source: &str) -> bool {
    ["http://", "https://", "webcal://"].iter().any(|scheme| source.starts_with(scheme))
}

// ------------------------------------------------------------------ feeds

/// (name, source) for each line that isn't blank or a comment
fn feeds(path: &Path) -> Vec<(String, String)> {
    let Ok(bytes) = fs::read(path) else { return vec![] };
    String::from_utf8_lossy(&bytes)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| match line.rsplit_once(char::is_whitespace) {
            Some((name, source)) => (name.trim().to_string(), source.to_string()),
            None => (String::new(), line.to_string()),
        })
        .collect()
}

/// Shared with the shell script it replaces, so the cache carries over
fn cache_file(source: &str) -> PathBuf {
    let digest = hex::encode(Sha256::digest(source.as_bytes()));
    cache_dir().join(format!("{}.ics", &digest[..24]))
}

fn stale(source: &str) -> bool {
    if !is_url(source) {
        return false;
    }
    match fs::metadata(cache_file(source)).and_then(|m| m.modified()) {
        Ok(modified) => SystemTime::now().duration_since(modified).unwrap_or_default() > STALE,
        Err(_) => true,
    }
}

fn read_text(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// The feed's text, fetched first when asked and it's a URL
fn read_feed(source: &str, fetch: bool) -> Result<Option<String>, String> {
    if !is_url(source) {
        let path = match source.strip_prefix("~/") {
            Some(rest) => home().join(rest),
            None => PathBuf::from(source),
        };
        return Ok(read_text(&path));
    }
    let cached = cache_file(source);
    if fetch {
        let url = source.replacen("webcal://", "https://", 1);
        let response = ureq::get(&url)
            .set("User-Agent", "neko-calendar")
            .timeout(StdDuration::from_secs(15))
            .call()
            .map_err(|error| error.to_string())?;
        let mut data = Vec::new();
        response.into_reader().read_to_end(&mut data).map_err(|error| error.to_string())?;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(cache_dir())
            .map_err(|error| error.to_string())?;
        let partial = cached.with_extension("part");
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&partial)
            .and_then(|mut file| file.write_all(&data))
            .map_err(|error| error.to_string())?;
        fs::rename(&partial, &cached).map_err(|error| error.to_string())?;
    }
    Ok(read_text(&cached))
}

// ---------------------------------------------------------------- parsing

/// A date for all-day values, else a moment in its own zone
#[derive(Clone, Copy, Debug)]
enum Time {
    Date(NaiveDate),
    At(DateTime<Tz>),
}

impl Time {
    fn local_day(&self) -> NaiveDate {
        match self {
            Time::Date(day) => *day,
            Time::At(at) => at.with_timezone(&Local).date_naive(),
        }
    }

    /// Instances compare by the minute in UTC, whatever zone they were written in
    fn key(&self) -> Key {
        match self {
            Time::Date(day) => Key::Day(*day),
            Time::At(at) => Key::Minute(at.timestamp().div_euclid(60)),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Key {
    Day(NaiveDate),
    Minute(i64),
}

fn local_at(naive: NaiveDateTime) -> DateTime<Tz> {
    Tz::LOCAL
        .from_local_datetime(&naive)
        .earliest()
        .unwrap_or_else(|| Tz::LOCAL.from_utc_datetime(&naive))
}

fn parse_time(value: &str, options: &HashMap<String, String>) -> Option<Time> {
    let value = value.trim();
    let all_digits = value.len() == 8 && value.bytes().all(|b| b.is_ascii_digit());
    if options.get("VALUE").map(String::as_str) == Some("DATE") || all_digits {
        return NaiveDate::parse_from_str(value.get(..8)?, "%Y%m%d").ok().map(Time::Date);
    }
    let naive = NaiveDateTime::parse_from_str(value.get(..15)?, "%Y%m%dT%H%M%S").ok()?;
    if value.ends_with('Z') {
        return Some(Time::At(Tz::UTC.from_utc_datetime(&naive)));
    }
    if let Some(zone) = options.get("TZID").and_then(|name| chrono_tz::Tz::from_str(name).ok()) {
        let tz = Tz::Tz(zone);
        if let Some(at) = tz.from_local_datetime(&naive).earliest() {
            return Some(Time::At(at));
        }
    }
    Some(Time::At(local_at(naive)))
}

fn parse_duration(value: &str) -> Option<Duration> {
    let value = value.trim();
    let (negative, rest) = match value.as_bytes().first() {
        Some(b'-') => (true, &value[1..]),
        Some(b'+') => (false, &value[1..]),
        _ => (false, value),
    };
    let mut rest = rest.strip_prefix('P')?;
    let mut total = Duration::zero();
    let mut in_time = false;
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('T') {
            in_time = true;
            rest = after;
            continue;
        }
        let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
        let number: i64 = rest.get(..digits)?.parse().ok()?;
        let unit = rest.as_bytes().get(digits)?;
        total += match (unit, in_time) {
            (b'W', false) => Duration::weeks(number),
            (b'D', false) => Duration::days(number),
            (b'H', true) => Duration::hours(number),
            (b'M', true) => Duration::minutes(number),
            (b'S', true) => Duration::seconds(number),
            _ => return None,
        };
        rest = &rest[digits + 1..];
    }
    Some(if negative { -total } else { total })
}

fn unfold(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for line in text.replace("\r\n", "\n").replace('\r', "\n").split('\n') {
        match line.chars().next() {
            Some(' ' | '\t') if !lines.is_empty() => lines.last_mut().unwrap().push_str(&line[1..]),
            _ => lines.push(line.to_string()),
        }
    }
    lines
}

fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n' | 'N') => out.push('\n'),
            Some(other @ ('\\' | ',' | ';')) => out.push(other),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

fn split_property(line: &str) -> (String, HashMap<String, String>, String) {
    let (head, value) = line.split_once(':').unwrap_or((line, ""));
    let mut parts = head.split(';');
    let name = parts.next().unwrap_or_default().to_uppercase();
    let options = parts
        .map(|param| {
            let (key, val) = param.split_once('=').unwrap_or((param, ""));
            (key.to_uppercase(), val.trim_matches('"').to_string())
        })
        .collect();
    (name, options, value.to_string())
}

#[derive(Default)]
struct Event {
    start: Option<Time>,
    end: Option<Time>,
    recurrence_id: Option<Time>,
    exdates: Vec<Time>,
    duration: Option<Duration>,
    summary: String,
    location: String,
    uid: Option<String>,
    status: String,
    rrule: Option<String>,
}

fn events(text: &str) -> Vec<Event> {
    let mut found = Vec::new();
    let mut current: Option<Event> = None;
    let mut depth = 0;
    for line in unfold(text) {
        if line == "BEGIN:VEVENT" {
            current = Some(Event::default());
            depth = 0;
            continue;
        }
        let Some(event) = current.as_mut() else { continue };
        if line.starts_with("BEGIN:") {
            depth += 1; // a VALARM inside the event
            continue;
        }
        if line.starts_with("END:") && depth > 0 {
            depth -= 1;
            continue;
        }
        if line == "END:VEVENT" {
            found.extend(current.take());
            continue;
        }
        if depth > 0 {
            continue;
        }
        let (name, options, value) = split_property(&line);
        match name.as_str() {
            "DTSTART" => event.start = parse_time(&value, &options),
            "DTEND" => event.end = parse_time(&value, &options),
            "RECURRENCE-ID" => event.recurrence_id = parse_time(&value, &options),
            "EXDATE" => event.exdates.extend(
                value.split(',').filter(|v| !v.is_empty()).filter_map(|v| parse_time(v, &options)),
            ),
            "DURATION" => event.duration = parse_duration(&value),
            "SUMMARY" => event.summary = unescape(&value),
            "LOCATION" => event.location = unescape(&value),
            "UID" => event.uid = Some(value),
            "STATUS" => event.status = value,
            "RRULE" => event.rrule = Some(value),
            _ => {}
        }
    }
    found
}

// -------------------------------------------------------------- recurrence

fn local_midnight(day: NaiveDate) -> DateTime<Tz> {
    local_at(day.and_time(NaiveTime::MIN))
}

/// Starts of a repeating event from `from` to `to` (local days, inclusive).
/// A rule rrule refuses (it validates strictly) leaves just the first start.
fn occurrences(start: Time, rule: &str, from: NaiveDate, to: NaiveDate) -> Vec<Time> {
    let only_start = || {
        let day = start.local_day();
        if day >= from && day <= to { vec![start] } else { vec![] }
    };
    // UNTIL is set separately below, as rrule wants it in UTC
    let mut until = None;
    let parts: Vec<&str> = rule
        .split(';')
        .filter(|part| match part.strip_prefix("UNTIL=") {
            Some(value) => {
                until = parse_time(value, &HashMap::new());
                false
            }
            None => !part.is_empty(),
        })
        .collect();
    let Ok(mut parsed) = RRule::<Unvalidated>::from_str(&parts.join(";")) else { return only_start() };

    // All-day events repeat from local midnight and come back as days
    let dt_start = match start {
        Time::Date(day) => local_midnight(day),
        Time::At(at) => at,
    };
    if let Some(until) = until {
        let end_of = |day: NaiveDate, zone: Tz| {
            zone.from_local_datetime(&day.and_hms_opt(23, 59, 59).unwrap())
                .latest()
                .unwrap_or_else(|| zone.from_utc_datetime(&day.and_hms_opt(23, 59, 59).unwrap()))
        };
        let until_at = match (until, start) {
            (Time::Date(day), Time::At(at)) => end_of(day, at.timezone()),
            (Time::Date(day), Time::Date(_)) => end_of(day, Tz::LOCAL),
            (Time::At(at), Time::Date(_)) => end_of(at.with_timezone(&Local).date_naive(), Tz::LOCAL),
            (Time::At(at), Time::At(_)) => at,
        };
        if until_at < dt_start {
            return vec![];
        }
        parsed = parsed.until(until_at.with_timezone(&Tz::UTC));
    }
    let Ok(set) = parsed.build(dt_start) else { return only_start() };
    let result = set.after(local_midnight(from)).before(local_midnight(to + Duration::days(1))).all(u16::MAX);
    result
        .dates
        .into_iter()
        .filter(|at| at.with_timezone(&Local).date_naive() <= to)
        .map(|at| match start {
            Time::Date(_) => Time::Date(at.with_timezone(&Local).date_naive()),
            Time::At(_) => Time::At(at),
        })
        .collect()
}

// ------------------------------------------------------------------ output

struct Entry {
    title: String,
    calendar: String,
    all_day: bool,
    start: String,
    end: String,
    location: String,
}

impl Entry {
    fn json(&self) -> Value {
        json!({
            "title": self.title,
            "calendar": self.calendar,
            "allDay": self.all_day,
            "start": self.start,
            "end": self.end,
            "location": self.location,
        })
    }
}

fn add_time(time: Time, length: Duration) -> Time {
    match time {
        Time::Date(day) => Time::Date(day + Duration::days(length.num_days())),
        Time::At(at) => Time::At(at + length),
    }
}

fn place(
    days: &mut BTreeMap<NaiveDate, Vec<Entry>>,
    event: &Event,
    start: Time,
    end: Option<Time>,
    name: &str,
    first: NaiveDate,
    last: NaiveDate,
) {
    let title = if event.summary.is_empty() { "(No title)".to_string() } else { event.summary.clone() };
    let mut add = |day: NaiveDate, all_day: bool, from: String, to: String| {
        if day >= first && day <= last {
            days.entry(day).or_default().push(Entry {
                title: title.clone(),
                calendar: name.to_string(),
                all_day,
                start: from,
                end: to,
                location: event.location.clone(),
            });
        }
    };
    match start {
        Time::At(start_at) => {
            let start_local = start_at.with_timezone(&Local);
            let end_at = match end {
                Some(Time::At(at)) => Some(at),
                _ => None,
            };
            let end_local = end_at.unwrap_or(start_at).with_timezone(&Local);
            let span_end = if end_local.time() != NaiveTime::MIN || end_local.date_naive() == start_local.date_naive() {
                end_local.date_naive()
            } else {
                end_local.date_naive() - Duration::days(1)
            };
            let mut day = start_local.date_naive();
            while day <= span_end {
                let from = if day == start_local.date_naive() { start_local.format("%H:%M").to_string() } else { String::new() };
                let to = match end_at {
                    Some(at) if at > start_at && day == end_local.date_naive() => end_local.format("%H:%M").to_string(),
                    _ => String::new(),
                };
                add(day, false, from, to);
                day += Duration::days(1);
            }
        }
        Time::Date(start_day) => {
            let span_end = match end {
                Some(Time::Date(end_day)) if end_day > start_day => end_day - Duration::days(1),
                _ => start_day,
            };
            let mut day = start_day;
            while day <= span_end {
                add(day, true, String::new(), String::new());
                day += Duration::days(1);
            }
        }
    }
}

fn collect(text: &str, name: &str, first: NaiveDate, last: NaiveDate, days: &mut BTreeMap<NaiveDate, Vec<Entry>>) {
    let found = events(text);
    let mut moved: HashMap<String, HashSet<Key>> = HashMap::new();
    for event in &found {
        if let (Some(id), Some(uid)) = (event.recurrence_id, &event.uid) {
            moved.entry(uid.clone()).or_default().insert(id.key());
        }
    }
    for event in &found {
        let Some(start) = event.start else { continue };
        if event.status.eq_ignore_ascii_case("CANCELLED") {
            continue;
        }
        let length = match (event.end, start) {
            (Some(Time::At(end)), Time::At(begin)) => Some(end - begin),
            (Some(Time::Date(end)), Time::Date(begin)) => Some(end - begin),
            (Some(_), _) => None,
            (None, _) => event.duration.or(match start {
                Time::Date(_) => Some(Duration::days(1)),
                Time::At(_) => None,
            }),
        };
        match (&event.rrule, event.recurrence_id) {
            (Some(rule), None) => {
                let mut skip: HashSet<Key> = event.exdates.iter().map(Time::key).collect();
                if let Some(ids) = event.uid.as_ref().and_then(|uid| moved.get(uid)) {
                    skip.extend(ids);
                }
                // A long event that began before the range still reaches into it
                let reach = first - length.filter(|l| *l > Duration::zero()).unwrap_or_else(Duration::zero) - Duration::days(1);
                for when in occurrences(start, rule, reach, last) {
                    if skip.contains(&when.key()) {
                        continue;
                    }
                    place(days, event, when, length.map(|l| add_time(when, l)), name, first, last);
                }
            }
            _ => place(days, event, start, length.map(|l| add_time(start, l)), name, first, last),
        }
    }
}

fn report(sources: &[(String, String)], first: NaiveDate, last: NaiveDate, fetch_stale: bool, errors: &mut Vec<String>) -> Value {
    let mut days: BTreeMap<NaiveDate, Vec<Entry>> = BTreeMap::new();
    for (name, source) in sources {
        let text = match read_feed(source, fetch_stale && stale(source)) {
            Ok(text) => text,
            Err(error) => {
                // Network, HTTP, disk: keep the cache
                let label = if is_url(source) {
                    if name.is_empty() { source.split('/').nth(2).unwrap_or(source).to_string() } else { name.clone() }
                } else {
                    source.clone()
                };
                errors.push(format!("{label}: {error}"));
                read_feed(source, false).ok().flatten()
            }
        };
        if let Some(text) = text {
            collect(&text, name, first, last, &mut days);
        }
    }
    let mut out = serde_json::Map::new();
    for (day, mut entries) in days {
        entries.sort_by(|a, b| {
            (!a.all_day, &a.start, a.title.to_lowercase()).cmp(&(!b.all_day, &b.start, b.title.to_lowercase()))
        });
        out.insert(day.format("%Y-%m-%d").to_string(), Value::Array(entries.iter().map(Entry::json).collect()));
    }
    Value::Object(out)
}

fn print_line(value: Value) {
    let mut stdout = std::io::stdout().lock();
    // A closed pipe (the shell gave up waiting) isn't worth a panic
    let _ = writeln!(stdout, "{value}");
    let _ = stdout.flush();
}

pub fn run(args: &[String]) -> Result<(), String> {
    let mut first = None;
    let mut last = None;
    let mut force = false;
    let mut config = home().join(".config/neko/calendars");
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--from" => first = it.next().cloned(),
            "--to" => last = it.next().cloned(),
            "--force" => force = true,
            "--config" => config = PathBuf::from(it.next().ok_or("--config needs a path")?),
            "-h" | "--help" => {
                println!("Usage: neko-calendar-events --from YYYY-MM-DD --to YYYY-MM-DD [--force] [--config PATH]");
                return Ok(());
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    let day = |value: Option<String>, flag: &str| -> Result<NaiveDate, String> {
        let value = value.ok_or(format!("{flag} YYYY-MM-DD is required"))?;
        NaiveDate::parse_from_str(&value, "%Y-%m-%d").map_err(|_| format!("{flag}: not a date: {value}"))
    };
    let first = day(first, "--from")?;
    let last = day(last, "--to")?;

    let sources = feeds(&config);
    if sources.is_empty() {
        print_line(json!({"configured": false, "days": {}, "errors": []}));
        return Ok(());
    }
    print_line(json!({"configured": true, "days": report(&sources, first, last, false, &mut vec![]), "errors": []}));
    if force || sources.iter().any(|(_, source)| stale(source)) {
        if force {
            for (_, source) in &sources {
                if is_url(source) {
                    if let Ok(file) = OpenOptions::new().write(true).open(cache_file(source)) {
                        let _ = file.set_modified(UNIX_EPOCH);
                    }
                }
            }
        }
        let mut errors = Vec::new();
        let days = report(&sources, first, last, true, &mut errors);
        print_line(json!({"configured": true, "days": days, "errors": errors}));
    }
    Ok(())
}
