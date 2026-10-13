//! The agents panel's collectors and account registry: one usage record per
//! agent (Claude Code, Codex, Grok, Fireworks), and the registry behind
//! `neko agent account`. What they share lives here: paths, the JSON caches,
//! times written the way the records always carried them, and the stats every
//! local scan adds up.

pub mod fireworks;
pub mod grok;

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Duration, FixedOffset, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde_json::{json, Map, Value};

// ------------------------------------------------------------------ paths

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

/// An XDG directory: the variable when set and not empty, else the default
pub fn xdg(var: &str, default: &str) -> PathBuf {
    match std::env::var_os(var) {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => home().join(default),
    }
}

pub fn env_or(var: &str, default: PathBuf) -> PathBuf {
    match std::env::var_os(var) {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => default,
    }
}

/// ~/.cache/neko/agent-usage, made if missing
pub fn cache_root() -> PathBuf {
    let root = xdg("XDG_CACHE_HOME", ".cache").join("neko/agent-usage");
    let _ = fs::create_dir_all(&root);
    root
}

pub fn state_root() -> PathBuf {
    xdg("XDG_STATE_HOME", ".local/state").join("neko/agents")
}

pub fn opencode_db() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("opencode/opencode.db")
}

// ------------------------------------------------------------------- JSON

pub fn read_json(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

pub fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
}

pub fn now_ms() -> i64 {
    (now_secs() * 1000.0).round() as i64
}

/// The file, if it was written no more than `max_age` seconds ago. A
/// modification time in the future means the clock went back since, so the
/// file's age can't be trusted.
pub fn read_fresh_json(path: &Path, max_age: f64) -> Option<Value> {
    if max_age <= 0.0 {
        return None;
    }
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    let mtime = modified.duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
    let age = now_secs() - mtime;
    if (0.0..=max_age).contains(&age) { read_json(path) } else { None }
}

/// Writes through a temporary file of this writer's own (several collectors
/// can run at once, and a shared temporary name would have the second rename
/// find the first one's file gone), then renames it into place.
pub fn write_json(path: &Path, value: &Value, mode: u32, newline: bool) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("cache");
    let tmp = path.with_file_name(format!(".{name}.{}.{}.tmp", std::process::id(), now_ms()));
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        let mut text = serde_json::to_string(value).unwrap_or_default();
        if newline {
            text.push('\n');
        }
        file.write_all(text.as_bytes())?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// The same with keys sorted all the way down, as json.dumps(sort_keys=True)
pub fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let ordered: BTreeMap<&String, Value> = map.iter().map(|(k, v)| (k, sorted(v))).collect();
            Value::Object(ordered.into_iter().map(|(k, v)| (k.clone(), v)).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// An exclusive lock held for as long as the returned file is
pub fn lock(path: &Path) -> std::io::Result<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new().write(true).create(true).truncate(false).open(path)?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(file)
}

// ---------------------------------------------------------------- numbers

/// A count from JSON as Python's round(float(value or 0)): strings and
/// floats too, anything else 0
pub fn number(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(n)) => n.as_i64().unwrap_or_else(|| round_half_even(n.as_f64().unwrap_or(0.0))),
        Some(Value::String(s)) => s.trim().parse::<f64>().map(round_half_even).unwrap_or(0),
        Some(Value::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

/// Python's int(value or 0): whole numbers only, a fraction truncated
pub fn int(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(n)) => n.as_i64().unwrap_or_else(|| n.as_f64().unwrap_or(0.0).trunc() as i64),
        Some(Value::String(s)) => s.trim().parse::<i64>().unwrap_or(0),
        Some(Value::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

pub fn round_half_even(x: f64) -> i64 {
    if !x.is_finite() {
        return 0;
    }
    let r = x.round();
    if (x - x.trunc()).abs() == 0.5 && (r as i64) % 2 != 0 {
        (r - x.signum()) as i64
    } else {
        r as i64
    }
}

/// A field's text, as str(value or "")
pub fn text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(Value::Bool(false)) => String::new(),
        Some(Value::Number(n)) if n.as_f64() == Some(0.0) => String::new(),
        Some(other) => other.to_string(),
    }
}

pub fn obj<'a>(value: Option<&'a Value>) -> Option<&'a Map<String, Value>> {
    value.and_then(Value::as_object)
}

// ------------------------------------------------------------------ times

/// A time as Python's datetime.fromisoformat reads it, Z allowed
pub enum Parsed {
    Aware(DateTime<FixedOffset>),
    Naive(NaiveDateTime),
}

pub fn parse_iso(raw: &str) -> Option<Parsed> {
    let s = raw.trim().replace('Z', "+00:00");
    if s.is_empty() {
        return None;
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f%:z", "%Y-%m-%d %H:%M:%S%.f%:z", "%Y-%m-%dT%H:%M%:z", "%Y-%m-%dT%H:%M:%S%.f%z"] {
        if let Ok(at) = DateTime::parse_from_str(&s, format) {
            return Some(Parsed::Aware(at));
        }
    }
    for format in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M"] {
        if let Ok(at) = NaiveDateTime::parse_from_str(&s, format) {
            return Some(Parsed::Naive(at));
        }
    }
    NaiveDate::parse_from_str(&s, "%Y-%m-%d").ok().map(|day| Parsed::Naive(day.and_hms_opt(0, 0, 0).unwrap()))
}

/// An ISO time as a moment, a time without a zone taken as UTC
pub fn parse_utc(raw: &str) -> Option<DateTime<FixedOffset>> {
    match parse_iso(raw)? {
        Parsed::Aware(at) => Some(at),
        Parsed::Naive(at) => Some(Utc.from_utc_datetime(&at).fixed_offset()),
    }
}

/// Python's isoformat: microseconds only when there are some, offset +HH:MM
pub fn iso<Tz: TimeZone>(at: &DateTime<Tz>) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let fixed = at.fixed_offset();
    let micros = fixed.timestamp_subsec_micros();
    let base = fixed.format("%Y-%m-%dT%H:%M:%S").to_string();
    let fraction = if micros > 0 { format!(".{micros:06}") } else { String::new() };
    format!("{base}{fraction}{}", fixed.format("%:z"))
}

pub fn iso_now_utc() -> String {
    iso(&Utc::now())
}

pub fn utc_from_secs(secs: f64) -> DateTime<Utc> {
    let whole = secs.floor();
    let nanos = ((secs - whole) * 1e9).round() as u32;
    Utc.timestamp_opt(whole as i64, nanos.min(999_999_999)).single().unwrap_or_default()
}

pub fn today() -> NaiveDate {
    Local::now().date_naive()
}

pub fn day_string(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

/// The last seven days, oldest first, ending today
pub fn recent_dates() -> Vec<String> {
    let today = today();
    (0..7).rev().map(|offset| day_string(today - Duration::days(offset))).collect()
}

/// The local day of a timestamp: seconds or milliseconds, or ISO text (a
/// time without a zone is already local); today when there's none
pub fn local_day(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => day_string(today()),
        Some(Value::Number(n)) => {
            let mut secs = n.as_f64().unwrap_or(0.0);
            if secs > 10_000_000_000.0 {
                secs /= 1000.0;
            }
            match Local.timestamp_opt(secs.floor() as i64, 0).single() {
                Some(at) => day_string(at.date_naive()),
                None => day_string(today()),
            }
        }
        Some(other) => {
            let raw = match other {
                Value::String(s) => s.clone(),
                v => v.to_string(),
            };
            match parse_iso(&raw) {
                Some(Parsed::Aware(at)) => day_string(at.with_timezone(&Local).date_naive()),
                Some(Parsed::Naive(at)) => day_string(at.date()),
                None => day_string(today()),
            }
        }
    }
}

/// The local zone in the terms a cached index records it, so records keyed
/// by local day are thrown out when the zone changes
pub fn zone_signature() -> Value {
    let now = Local::now();
    let january = Local.with_ymd_and_hms(now.year_ce().1 as i32, 1, 1, 12, 0, 0).single();
    let july = Local.with_ymd_and_hms(now.year_ce().1 as i32, 7, 1, 12, 0, 0).single();
    json!([
        std::env::var("TZ").ok(),
        january.map(|at| at.offset().local_minus_utc()),
        july.map(|at| at.offset().local_minus_utc()),
    ])
}

use chrono::Datelike;

// ------------------------------------------------------------------ stats

/// Token totals by kind, as every record's modelUsage holds them
#[derive(Default, Clone, Copy)]
pub struct Bucket {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
}

impl Bucket {
    pub fn json(&self) -> Value {
        json!({
            "inputTokens": self.input,
            "outputTokens": self.output,
            "cacheReadInputTokens": self.cache_read,
            "cacheCreationInputTokens": self.cache_write,
        })
    }

    pub fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }

    pub fn add(&mut self, other: &Bucket) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
    }
}

/// Local usage added up message by message into the fields every record
/// carries. recentDays' messageCount is a token total, despite the name the
/// synced snapshots share.
pub struct Tally {
    today: String,
    recent: Vec<String>,
    recent_tokens: BTreeMap<String, i64>,
    pub prompts: i64,
    today_prompts: i64,
    today_tokens: i64,
    today_by_model: Map<String, Value>,
    sessions: BTreeSet<String>,
    today_sessions: BTreeSet<String>,
    active_days: BTreeSet<String>,
    models: Vec<(String, Bucket)>,
}

impl Default for Tally {
    fn default() -> Self {
        let recent = recent_dates();
        Tally {
            today: day_string(today()),
            recent_tokens: recent.iter().map(|d| (d.clone(), 0)).collect(),
            recent,
            prompts: 0,
            today_prompts: 0,
            today_tokens: 0,
            today_by_model: Map::new(),
            sessions: BTreeSet::new(),
            today_sessions: BTreeSet::new(),
            active_days: BTreeSet::new(),
            models: Vec::new(),
        }
    }
}

impl Tally {
    pub fn today(&self) -> &str {
        &self.today
    }

    /// `prompts` messages of one model, on one day, in one session
    pub fn add(&mut self, day: &str, session: &str, model: &str, usage: Bucket, prompts: i64) {
        let total = usage.total();
        self.sessions.insert(session.to_string());
        self.active_days.insert(day.to_string());
        self.prompts += prompts;
        match self.models.iter_mut().find(|(name, _)| name == model) {
            Some((_, bucket)) => bucket.add(&usage),
            None => self.models.push((model.to_string(), usage)),
        }
        if let Some(tokens) = self.recent_tokens.get_mut(day) {
            *tokens += total;
        }
        if day == self.today {
            self.today_prompts += prompts;
            self.today_sessions.insert(session.to_string());
            self.today_tokens += total;
            let current = self.today_by_model.get(model).and_then(Value::as_i64).unwrap_or(0);
            self.today_by_model.insert(model.to_string(), json!(current + total));
        }
    }

    pub fn drop_session(&mut self, session: &str) {
        self.sessions.remove(session);
        self.today_sessions.remove(session);
    }

    pub fn add_session(&mut self, session: &str, today: bool) {
        self.sessions.insert(session.to_string());
        if today {
            self.today_sessions.insert(session.to_string());
        }
    }

    pub fn json(&self) -> Value {
        json!({
            "todayPrompts": self.today_prompts,
            "todaySessions": self.today_sessions.len(),
            "todayTotalTokens": self.today_tokens,
            "todayTokensByModel": Value::Object(self.today_by_model.clone()),
            "recentDays": self.recent.iter().map(|d| json!({"date": d, "messageCount": self.recent_tokens[d]})).collect::<Vec<_>>(),
            "modelUsage": Value::Object(self.models.iter().map(|(name, bucket)| (name.clone(), bucket.json())).collect()),
            "totalPrompts": self.prompts,
            "totalSessions": self.sessions.len(),
            "activeDays": self.active_days.len(),
            "activeDates": self.active_days.iter().collect::<Vec<_>>(),
        })
    }
}

/// Two stats dicts as one: counts summed, days by date, active dates unioned
pub fn merge_stats(base: &Value, extra: &Value) -> Value {
    let mut merged = base.as_object().cloned().unwrap_or_default();
    for key in ["todayPrompts", "todaySessions", "todayTotalTokens", "totalPrompts", "totalSessions"] {
        merged.insert(key.into(), json!(number(base.get(key)) + number(extra.get(key))));
    }

    let mut combined = obj(base.get("todayTokensByModel")).cloned().unwrap_or_default();
    for (model, count) in obj(extra.get("todayTokensByModel")).into_iter().flatten() {
        let sum = number(combined.get(model)) + number(Some(count));
        combined.insert(model.clone(), json!(sum));
    }
    merged.insert("todayTokensByModel".into(), Value::Object(combined));

    let mut usage = obj(base.get("modelUsage")).cloned().unwrap_or_default();
    for (model, bucket) in obj(extra.get("modelUsage")).into_iter().flatten() {
        let target = usage.entry(model.clone()).or_insert_with(|| Bucket::default().json());
        if let (Some(target), Some(bucket)) = (target.as_object_mut(), bucket.as_object()) {
            for (field, count) in bucket {
                let sum = number(target.get(field)) + number(Some(count));
                target.insert(field.clone(), json!(sum));
            }
        }
    }
    merged.insert("modelUsage".into(), Value::Object(usage));

    let mut by_date: BTreeMap<String, i64> = BTreeMap::new();
    for source in [base.get("recentDays"), extra.get("recentDays")] {
        for day in source.and_then(Value::as_array).into_iter().flatten() {
            let date = text(day.get("date"));
            if !date.is_empty() {
                *by_date.entry(date).or_default() += number(day.get("messageCount"));
            }
        }
    }
    merged.insert(
        "recentDays".into(),
        by_date.iter().map(|(date, count)| json!({"date": date, "messageCount": count})).collect(),
    );

    // Sources overlap in time, so dates union rather than counts summing; a
    // fallback that only knows a count still bounds the answer from below
    let dates: BTreeSet<String> = [base.get("activeDates"), extra.get("activeDates")]
        .into_iter()
        .flat_map(|list| list.and_then(Value::as_array).into_iter().flatten())
        .filter_map(|d| d.as_str().map(String::from))
        .collect();
    let days = (dates.len() as i64).max(number(base.get("activeDays"))).max(number(extra.get("activeDays")));
    merged.insert("activeDates".into(), json!(dates));
    merged.insert("activeDays".into(), json!(days));
    Value::Object(merged)
}

// --------------------------------------------------------------- accounts

/// The accounts `neko agent account` registered for a provider, read straight
/// from its registry, each marked active or not and carrying the switch
/// policy. Only a registry with a second account matters; with one, the
/// record describes the primary home alone.
pub fn registered_accounts(provider: &str) -> Vec<Map<String, Value>> {
    let registry = read_json(&state_root().join(format!("accounts/{provider}.json"))).unwrap_or(Value::Null);
    let mut accounts: Vec<Map<String, Value>> = registry
        .get("accounts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|a| a.as_object().cloned())
        .filter(|a| !text(a.get("id")).is_empty())
        .collect();
    if accounts.len() < 2 {
        return vec![];
    }
    let mut active = text(registry.get("active"));
    if active.is_empty() || !accounts.iter().any(|a| text(a.get("id")) == active) {
        active = text(accounts[0].get("id"));
    }
    let threshold = match registry.get("threshold") {
        Some(v) if !text(Some(v)).is_empty() => v.clone(),
        _ => json!(95),
    };
    let switch = json!({
        "mode": if registry.get("switch").and_then(Value::as_str) == Some("auto") { "auto" } else { "manual" },
        "threshold": threshold,
    });
    for account in &mut accounts {
        let is_active = text(account.get("id")) == active;
        account.insert("active".into(), json!(is_active));
        account.insert("switch".into(), switch.clone());
    }
    accounts
}

/// Characters a cache name keeps from an identity
pub fn safe_key(raw: &str) -> String {
    raw.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect()
}

/// Every file under `root` whose name ends with `suffix`, depth first in
/// directory order (files of a directory before its subdirectories)
pub fn files_under(root: &Path, suffix: &str, skip_hidden: bool) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        let mut subdirs = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if skip_hidden && name.starts_with('.') {
                continue;
            }
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => subdirs.push(path),
                Ok(kind) if (kind.is_file() || kind.is_symlink()) && name.ends_with(suffix) => {
                    if path.is_file() {
                        out.push(path)
                    }
                }
                _ => {}
            }
        }
        // Visited in the order found, so the first found is walked first
        stack.extend(subdirs.into_iter().rev());
    }
    out
}

/// pi's and omp's session roots: the default one and one per profile
/// (`--profile=<name>` moves the whole tree under profiles/<name>/)
pub fn pi_session_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for base in [home().join(".pi"), home().join(".omp")] {
        roots.push(base.join("agent/sessions"));
        if let Ok(entries) = fs::read_dir(base.join("profiles")) {
            let mut profiles: Vec<PathBuf> =
                entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).map(|p| p.join("agent/sessions")).collect();
            profiles.sort();
            roots.extend(profiles);
        }
    }
    roots
}

/// The collector subcommands share their flags: --force, --limits-only
pub struct Flags {
    pub force: bool,
    pub limits_only: bool,
    pub rest: Vec<(String, String)>,
}

pub fn flags(args: &[String], with_values: &[&str]) -> Result<Flags, String> {
    let mut parsed = Flags { force: false, limits_only: false, rest: vec![] };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--force" => parsed.force = true,
            "--limits-only" => parsed.limits_only = true,
            flag if with_values.contains(&flag) => {
                let value = it.next().ok_or(format!("{flag} needs a value"))?;
                parsed.rest.push((flag.to_string(), value.clone()));
            }
            other => {
                if let Some((flag, value)) = other.split_once('=') {
                    if with_values.contains(&flag) {
                        parsed.rest.push((flag.to_string(), value.to_string()));
                        continue;
                    }
                }
                return Err(format!("unknown argument: {other}"));
            }
        }
    }
    Ok(parsed)
}

pub fn print_compact(value: &Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{}", serde_json::to_string(value).unwrap_or_default());
}

/// Python's truthiness, for flags stored loosely
pub fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64() != Some(0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
    }
}
