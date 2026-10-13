//! Claude Code usage as one display-ready JSON record.
//!
//! Everything the agents panel shows for Claude comes from this one command:
//! local transcript stats from ~/.claude/projects, the stats-cache and
//! history fallbacks for machines without transcripts, pi/omp and opencode
//! sessions that ran on an Anthropic provider, and the authoritative rate
//! limits from Anthropic's OAuth usage endpoint. The panel itself only ever
//! reads the JSON this prints; it never talks to disk formats or endpoints.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Local, TimeZone, Utc};
use serde_json::{json, Map, Value};

use super::{
    cache_root, day_string, expand_path, home, iso, local_day, merge_stats, now_ms, now_secs, number, parse_iso, read_fresh_json, read_json, sha1_hex, sorted,
    text, truthy, write_json, Bucket, Parsed, Tally,
};

const AUTH_HELP: &str = "Run `claude auth login` to restore authoritative usage.";
const USAGE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const PROBE_MIN_INTERVAL_SECONDS: f64 = 15.0;
// Anthropic rate-limits its usage endpoint readily. A refused re-check of
// numbers this recent still describes the account; only older ones are
// reported as stale.
const CURRENT_ENOUGH_SECONDS: f64 = 900.0;

pub fn run(args: &[String]) -> Result<(), String> {
    let flags = super::flags(args, &["--cache-seconds"])?;
    let cache_seconds = match flags.rest.iter().rev().find(|(flag, _)| flag == "--cache-seconds") {
        Some((_, value)) => value.trim().parse::<f64>().map_err(|_| format!("--cache-seconds: invalid float value: '{value}'"))?,
        None => 20.0,
    };

    let claude_dir = config_dir();
    let scan_age = if flags.force { 0.0 } else if flags.limits_only { 900.0 } else { cache_seconds };
    let mut stats = cached_scan(&claude_dir.join("projects"), scan_age, !flags.force);

    if number(stats.get("totalPrompts")) <= 0 {
        if let Some(fallback) = stats_cache_fallback(&claude_dir) {
            stats = fallback;
        } else {
            // No transcripts and no aggregate cache, but history.jsonl alone
            // can still put numbers on today.
            let (prompts, sessions) = today_prompts_from_history(&claude_dir);
            if prompts > 0 || sessions > 0 {
                stats["todayPrompts"] = json!(prompts);
                stats["todaySessions"] = json!(sessions);
            }
        }
    }
    if let Some(pi) = scan_pi_usage(scan_age) {
        stats = merge_stats(&stats, &pi);
    }
    if let Some(opencode) = scan_opencode_usage(scan_age) {
        stats = merge_stats(&stats, &opencode);
    }

    let registered = super::registered_accounts("claude");
    let accounts: Vec<Value> = registered.iter().map(|account| account_limits(account, flags.force)).collect();
    let current = accounts.iter().find(|a| a["active"] == json!(true));
    let (plan, limits, stale, fetched_at) = match current {
        // The top-level fields keep describing the account new sessions use,
        // so the bar icon and anything else reading one set of limits stays
        // right.
        Some(current) => (
            text(current.get("plan")),
            Limits {
                limits: current["limits"].clone(),
                status: text(current.get("usageStatusText")),
                help: text(current.get("authHelpText")),
                live: false,
                fetched_at: 0,
                retry: current["retryAdvised"] == json!(true),
            },
            current["stale"] == json!(true),
            current["fetchedAt"].clone(),
        ),
        None => {
            let login = oauth_login(&claude_dir);
            let limits = collect_limits(&login, flags.force, "claude-limits.json");
            let (stale, fetched_at) = (!limits.live, json!(limits.fetched_at));
            (login.plan, limits, stale, fetched_at)
        }
    };

    let has_limits = limits.limits.as_array().is_some_and(|l| !l.is_empty());
    let mut record = json!({
        "schemaVersion": 1,
        "id": "claude",
        "name": "Claude Code",
        "updatedAt": super::iso_now_utc(),
        "ready": number(stats.get("totalPrompts")) > 0 || has_limits,
        "hasLocalStats": true,
        "tierLabel": plan,
        "usageStatusText": limits.status,
        "authHelpText": limits.help,
        "limits": limits.limits,
        // Numbers kept past a failed probe, and when they were measured, so
        // the panel can tell them apart from ones checked just now.
        "limitsStale": stale,
        "limitsFetchedAt": fetched_at,
    });
    let map = record.as_object_mut().unwrap();
    if limits.retry {
        map.insert("retryAdvised".into(), json!(true));
    }
    if !accounts.is_empty() {
        map.insert("accountSwitch".into(), registered[0]["switch"].clone());
        map.insert("accounts".into(), Value::Array(accounts));
    }
    if let Value::Object(stats) = stats {
        map.extend(stats);
    }
    super::print_compact(&sorted(&record));
    Ok(())
}

fn config_dir() -> PathBuf {
    match std::env::var("CLAUDE_CONFIG_DIR") {
        Ok(dir) if !dir.is_empty() => expand_path(&dir),
        _ => expand_path("~/.claude"),
    }
}

/// usage[snake] when the key is there at all, else usage[camel], as a count
fn usage_token(usage: &Map<String, Value>, snake: &str, camel: &str) -> i64 {
    number(if usage.contains_key(snake) { usage.get(snake) } else { usage.get(camel) })
}

// ------------------------------------------------------------- local scan
//
// Transcripts are append-only, and most of the corpus never changes between
// ticks, so the scan keeps a per-file index: the unique usage records already
// parsed out of each file plus the byte offset they end at. A file whose size
// and mtime match the index is not opened; a file that grew is read from the
// stored offset; anything else (truncated, rewritten, replaced, unknown) is
// read from the start. Without this the whole history was re-parsed every
// refresh, and the cost grew for the life of the machine.

// The Python collector wrote version 4 to the same file; either one reads
// only its own and rebuilds over the other's.
const INDEX_VERSION: i64 = 5;

// How much of each end of what was read the index remembers a hash of, so a
// file replaced or rewritten with more than it had is not mistaken for an
// append.
const INDEX_HEAD_BYTES: u64 = 4096;

/// One assistant message's usage; `day` is None when the line carried no
/// timestamp
#[derive(Clone, PartialEq)]
struct Usage {
    key: String,
    model: String,
    day: Option<String>,
    tokens: Bucket,
    session: String,
}

#[derive(Clone, PartialEq)]
struct Entry {
    size: u64,
    file: (u64, u64),
    mtime: i64,
    head: String,
    offset: u64,
    lines: u64,
    records: Vec<Usage>,
}

impl Entry {
    fn json(&self) -> Value {
        let records: Vec<Value> = self
            .records
            .iter()
            .map(|r| json!([r.key, r.model, r.day, r.tokens.input, r.tokens.output, r.tokens.cache_read, r.tokens.cache_write, r.session]))
            .collect();
        json!({
            "size": self.size,
            "file": [self.file.0, self.file.1],
            "mtime": self.mtime,
            "head": self.head,
            "offset": self.offset,
            "lines": self.lines,
            "records": records,
        })
    }

    fn from_json(value: &Value) -> Option<Entry> {
        let file = value.get("file")?.as_array()?;
        let records = value
            .get("records")?
            .as_array()?
            .iter()
            .map(|r| {
                let r = r.as_array()?;
                Some(Usage {
                    key: r.first()?.as_str()?.to_string(),
                    model: r.get(1)?.as_str()?.to_string(),
                    day: r.get(2)?.as_str().map(String::from),
                    tokens: Bucket { input: r.get(3)?.as_i64()?, output: r.get(4)?.as_i64()?, cache_read: r.get(5)?.as_i64()?, cache_write: r.get(6)?.as_i64()? },
                    session: r.get(7)?.as_str()?.to_string(),
                })
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Entry {
            size: value.get("size")?.as_u64()?,
            file: (file.first()?.as_u64()?, file.get(1)?.as_u64()?),
            mtime: value.get("mtime")?.as_i64()?,
            head: value.get("head")?.as_str()?.to_string(),
            offset: value.get("offset")?.as_u64()?,
            lines: value.get("lines")?.as_u64()?,
            records,
        })
    }
}

fn load_index(index_file: &Path) -> HashMap<String, Entry> {
    let Some(data) = read_json(index_file) else { return HashMap::new() };
    if data.get("version").and_then(Value::as_i64) != Some(INDEX_VERSION) || data.get("zone") != Some(&super::zone_signature()) {
        return HashMap::new();
    }
    data.get("files")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .filter_map(|(path, entry)| Some((path.clone(), Entry::from_json(entry)?)))
        .collect()
}

/// What was already read, by its first and last few kilobytes: a transcript
/// rewritten in place rather than appended to changes one or the other
fn read_digest(path: &Path, length: u64) -> std::io::Result<String> {
    use sha1::Digest;
    let mut digest = sha1::Sha1::new();
    let mut handle = File::open(path)?;
    let take = length.min(INDEX_HEAD_BYTES);
    let mut buffer = Vec::new();
    (&mut handle).take(take).read_to_end(&mut buffer)?;
    digest.update(&buffer);
    handle.seek(SeekFrom::Start(length.saturating_sub(INDEX_HEAD_BYTES)))?;
    buffer.clear();
    handle.take(take).read_to_end(&mut buffer)?;
    digest.update(&buffer);
    Ok(hex::encode(digest.finalize()))
}

/// The index entry for one transcript, reusing `entry` where the file only
/// grew
fn parse_usage_records(path: &Path, entry: Option<&Entry>) -> std::io::Result<Entry> {
    let stat = fs::metadata(path)?;
    let size = stat.size();
    let mtime = stat.mtime() * 1_000_000_000 + stat.mtime_nsec();
    let file = (stat.dev(), stat.ino());

    if let Some(entry) = entry {
        if entry.size == size && entry.mtime == mtime {
            return Ok(entry.clone());
        }
    }

    // Only the same file, grown past what was read with what was read still
    // in place, is an append. A transcript replaced by a larger one is a new
    // file, and one rewritten in place has a different start or end.
    let appended = entry.filter(|e| size > e.size && e.file == file && read_digest(path, e.offset).ok().as_deref() == Some(e.head.as_str()));
    let (mut records, mut offset, mut line_number) = match appended {
        Some(e) => (e.records.clone(), e.offset, e.lines),
        None => (Vec::new(), 0, 0),
    };

    // A streamed response is several lines sharing one message id, and the
    // first line's output_tokens is a placeholder while the last carries the
    // real count. Keep each message's line with the highest output count
    // (the last one read wins a tie), whole: a response that fell back to
    // another model mid-stream has lines that are separate snapshots, and
    // mixing fields across them over-counts cache tokens and credits the
    // wrong model.
    let mut positions: HashMap<String, usize> = records.iter().enumerate().map(|(i, r)| (r.key.clone(), i)).collect();
    let mut handle = File::open(path)?;
    handle.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::with_capacity(1 << 16, handle);
    let mut raw = Vec::new();
    let path_text = path.to_string_lossy();
    loop {
        raw.clear();
        if reader.read_until(b'\n', &mut raw)? == 0 || raw.last() != Some(&b'\n') {
            // The end, or a line still being written: picked up whole next time
            break;
        }
        offset += raw.len() as u64;
        line_number += 1;

        // A cheap filter before parsing keeps files of unrelated lines cheap
        if !contains(&raw, b"\"usage\":") {
            continue;
        }
        let Ok(Value::Object(parsed)) = serde_json::from_str::<Value>(&String::from_utf8_lossy(&raw)) else { continue };
        let empty = Map::new();
        let message = parsed.get("message").and_then(Value::as_object).unwrap_or(&empty);
        if parsed.get("type").and_then(Value::as_str) != Some("assistant") && message.get("role").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let usage = [message.get("usage"), parsed.get("usage")].into_iter().find(|u| truthy(*u)).flatten();
        let Some(usage) = usage.and_then(Value::as_object) else { continue };

        let message_id = [message.get("id"), parsed.get("messageId")].into_iter().find(|v| truthy(*v)).flatten();
        let key = match message_id {
            Some(id) => text(Some(id)),
            None => {
                let fallback = [parsed.get("uuid"), parsed.get("requestId")].into_iter().find(|v| truthy(*v)).flatten();
                format!("{path_text}:{}", fallback.map(|v| text(Some(v))).unwrap_or_else(|| line_number.to_string()))
            }
        };

        let tokens = Bucket {
            input: usage_token(usage, "input_tokens", "inputTokens"),
            output: usage_token(usage, "output_tokens", "outputTokens"),
            cache_read: usage_token(usage, "cache_read_input_tokens", "cacheReadInputTokens"),
            cache_write: usage_token(usage, "cache_creation_input_tokens", "cacheCreationInputTokens"),
        };
        if tokens.total() <= 0 {
            continue;
        }
        let held = positions.get(&key).copied();
        if held.is_some_and(|i| tokens.output < records[i].tokens.output) {
            continue;
        }

        let timestamp = if truthy(parsed.get("timestamp")) { parsed.get("timestamp") } else { message.get("timestamp") };
        let model = [message.get("model"), parsed.get("model")].into_iter().find(|v| truthy(*v)).flatten();
        let session = text(parsed.get("sessionId"));
        let record = Usage {
            key: key.clone(),
            model: model.map(|m| text(Some(m))).unwrap_or_else(|| "claude".into()),
            day: timestamp.filter(|t| !t.is_null()).map(|t| local_day(Some(t))),
            tokens,
            session: if session.is_empty() { path_text.to_string() } else { session },
        };
        match held {
            Some(i) => records[i] = record,
            None => {
                positions.insert(key, records.len());
                records.push(record);
            }
        }
    }

    Ok(Entry { size, file, mtime, head: read_digest(path, offset)?, offset, lines: line_number, records })
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn scan_projects(projects: &Path, index_file: &Path) -> Value {
    let previous = load_index(index_file);
    let mut current: HashMap<String, Entry> = HashMap::new();

    // Directory order: when one API message shows up in several transcripts
    // with the same output count, the last file visited wins.
    let mut order: Vec<String> = Vec::new();
    let mut unreadable = 0;
    let mut examples: Vec<String> = Vec::new();
    let files = if projects.is_dir() { super::files_under(projects, ".jsonl", false) } else { vec![] };
    for path in files {
        let key = path.to_string_lossy().to_string();
        match parse_usage_records(&path, previous.get(&key)) {
            Ok(entry) => {
                current.insert(key.clone(), entry);
            }
            Err(error) => {
                unreadable += 1;
                if examples.len() < 3 {
                    examples.push(format!("{key}: {error}"));
                }
                // What was read before is still true of the file
                if let Some(entry) = previous.get(&key) {
                    current.insert(key.clone(), entry.clone());
                }
            }
        }
        if current.contains_key(&key) {
            order.push(key);
        }
    }
    if unreadable > 0 {
        eprintln!("Ignoring {unreadable} unreadable Claude project files (examples: {})", examples.join("; "));
    }

    if current != previous {
        let files: Map<String, Value> = current.iter().map(|(path, entry)| (path.clone(), entry.json())).collect();
        let index = json!({"version": INDEX_VERSION, "zone": super::zone_signature(), "files": files});
        if let Err(error) = write_json(index_file, &sorted(&index), 0o644, true) {
            eprintln!("Could not write Claude scan index {}: {error}", index_file.display());
        }
    }

    // One API message can show up in several transcripts (a resumed session
    // carries the earlier ones). As within a file, the record with the
    // highest output count wins, the last one visited breaking a tie.
    let mut seen: HashMap<&str, &Usage> = HashMap::new();
    let mut first_seen: Vec<&str> = Vec::new();
    for key in &order {
        for record in &current[key].records {
            match seen.get(record.key.as_str()) {
                Some(held) if record.tokens.output < held.tokens.output => continue,
                Some(_) => {}
                None => first_seen.push(&record.key),
            }
            seen.insert(&record.key, record);
        }
    }

    let mut tally = Tally::default();
    let today = tally.today().to_string();
    for key in first_seen {
        let record = seen[key];
        let day = record.day.clone().unwrap_or_else(|| today.clone());
        tally.add(&day, &record.session, &record.model, record.tokens, 1);
    }
    tally.json()
}

fn cached_scan(projects: &Path, max_age: f64, use_index: bool) -> Value {
    let digest = &sha1_hex(&projects.to_string_lossy())[..16];
    let root = cache_root();
    let cache_file = root.join(format!("claude-scan-{digest}.json"));
    let index_file = root.join(format!("claude-index-{digest}.json"));

    if let Some(cached) = read_fresh_json(&cache_file, max_age) {
        return cached;
    }
    let _lock = super::lock(&root.join(format!("claude-scan-{digest}.lock")));
    if let Some(cached) = read_fresh_json(&cache_file, max_age) {
        return cached;
    }
    if !use_index {
        let _ = fs::remove_file(&index_file);
    }
    let summary = scan_projects(projects, &index_file);
    let _ = write_json(&cache_file, &sorted(&summary), 0o644, true);
    summary
}

// --------------------------------------------------------- local fallback
//
// A machine without transcripts on disk can still know its history: Claude
// Code keeps aggregate counters in stats-cache.json and per-prompt history in
// history.jsonl. Only consulted when the project scan comes back empty.

fn stats_cache_fallback(claude_dir: &Path) -> Option<Value> {
    let data = read_json(&claude_dir.join("stats-cache.json"))?;
    let today = day_string(super::today());
    let list = |key: &str| data.get(key).and_then(Value::as_array).cloned().unwrap_or_default();

    let today_tokens = list("dailyModelTokens")
        .iter()
        .find(|entry| entry.get("date").and_then(Value::as_str) == Some(today.as_str()))
        .map(|entry| entry.get("tokensByModel").filter(|t| truthy(Some(t))).cloned().unwrap_or(json!({})))
        .unwrap_or(json!({}));

    let daily: Vec<Value> = list("dailyActivity").into_iter().filter(Value::is_object).collect();
    let active: std::collections::BTreeSet<String> =
        daily.iter().filter(|day| number(day.get("messageCount")) > 0 && truthy(day.get("date"))).map(|day| text(day.get("date"))).collect();
    let (today_prompts, today_sessions) = today_prompts_from_history(claude_dir);
    let today_total: i64 = today_tokens.as_object().into_iter().flatten().map(|(_, v)| number(Some(v))).sum();

    Some(json!({
        "todayPrompts": today_prompts,
        "todaySessions": today_sessions,
        "todayTotalTokens": today_total,
        "todayTokensByModel": today_tokens,
        "recentDays": daily[daily.len().saturating_sub(7)..],
        "modelUsage": data.get("modelUsage").filter(|m| truthy(Some(m))).cloned().unwrap_or(json!({})),
        "totalPrompts": number(data.get("totalMessages")),
        "totalSessions": number(data.get("totalSessions")),
        "activeDays": active.len(),
        "activeDates": active,
    }))
}

fn today_prompts_from_history(claude_dir: &Path) -> (i64, usize) {
    let midnight = super::today().and_hms_opt(0, 0, 0).unwrap();
    let start_of_day = Local.from_local_datetime(&midnight).earliest().map(|at| at.timestamp_millis()).unwrap_or(0) as f64;
    let Ok(bytes) = fs::read(claude_dir.join("history.jsonl")) else { return (0, 0) };
    let content = String::from_utf8_lossy(&bytes);
    let mut prompts = 0;
    let mut sessions = HashSet::new();
    for line in content.lines().rev() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
        if (number(entry.get("timestamp")) as f64) < start_of_day {
            break;
        }
        prompts += 1;
        if truthy(entry.get("sessionId")) {
            sessions.insert(text(entry.get("sessionId")));
        }
    }
    (prompts, sessions.len())
}

// ------------------------------------------------------------ pi and omp
//
// These agents can consume a Claude subscription without writing native
// Claude Code transcripts. Their compatible JSONL session formats carry the
// provider, model, and token usage on every assistant message.

fn scan_pi_usage(max_age: f64) -> Option<Value> {
    let cache_file = cache_root().join("claude-pi-sessions.json");
    if let Some(cached) = read_fresh_json(&cache_file, max_age) {
        return cached.get("stats").filter(|s| !s.is_null()).cloned();
    }

    let mut tally = Tally::default();
    let mut seen = HashSet::new();
    for root in super::pi_session_roots() {
        let files = if root.is_dir() { super::files_under(&root, ".jsonl", false) } else { vec![] };
        for path in files {
            let Ok(bytes) = fs::read(&path) else { continue };
            let content = String::from_utf8_lossy(&bytes);
            let session = path.to_string_lossy().to_string();
            for (index, line) in content.lines().enumerate() {
                if !line.contains("\"usage\"") || !line.contains("\"assistant\"") {
                    continue;
                }
                let Ok(Value::Object(entry)) = serde_json::from_str::<Value>(line) else { continue };
                let empty = Map::new();
                let message = entry.get("message").and_then(Value::as_object).unwrap_or(&empty);
                if entry.get("type").and_then(Value::as_str) != Some("message") || message.get("role").and_then(Value::as_str) != Some("assistant") {
                    continue;
                }
                if text(message.get("provider")) != "anthropic" {
                    continue;
                }
                let id = if truthy(entry.get("id")) { text(entry.get("id")) } else { (index + 1).to_string() };
                if !seen.insert(format!("{session}:{id}")) {
                    continue;
                }
                let usage = match message.get("usage") {
                    Some(u) if truthy(Some(u)) => match u.as_object() {
                        Some(u) => u.clone(),
                        None => continue,
                    },
                    _ => Map::new(),
                };
                let mut tokens = Bucket {
                    input: usage_token(&usage, "input", "inputTokens"),
                    output: usage_token(&usage, "output", "outputTokens"),
                    cache_read: usage_token(&usage, "cacheRead", "cache_read_input_tokens"),
                    cache_write: usage_token(&usage, "cacheWrite", "cache_creation_input_tokens"),
                };
                let mut total = tokens.total();
                if total <= 0 {
                    // Only a total: it counts as input
                    total = number(usage.get("totalTokens"));
                    tokens.input = total;
                }
                if total <= 0 {
                    continue;
                }
                let model = message.get("model").filter(|m| truthy(Some(m))).map(|m| text(Some(m))).unwrap_or_else(|| "claude".into());
                let stamp = if truthy(entry.get("timestamp")) { entry.get("timestamp") } else { message.get("timestamp") };
                tally.add_with_total(&local_day(stamp), &session, &model, tokens, total, 1);
            }
        }
    }

    let stats = if tally.prompts > 0 { tally.json() } else { Value::Null };
    let _ = write_json(&cache_file, &json!({"stats": stats}), 0o644, true);
    Some(stats).filter(|s| !s.is_null())
}

// --------------------------------------------------------------- opencode
//
// A Claude subscription burned entirely through opencode never writes a
// transcript under ~/.claude, but opencode records per-message provider,
// model, and token usage in its own database. Scan it for Anthropic-provider
// messages and merge the result into whatever the transcript scan found.

fn scan_opencode_usage(max_age: f64) -> Option<Value> {
    let db = super::opencode_db();
    if !db.is_file() {
        return None;
    }
    // Same freshness contract as the transcript scan: --limits-only promises
    // to reuse recent local stats, and a big opencode history walked on every
    // panel open would break that promise.
    let cache_file = cache_root().join(format!("claude-opencode-{}.json", &sha1_hex(&db.to_string_lossy())[..16]));
    if let Some(cached) = read_fresh_json(&cache_file, max_age) {
        return cached.get("stats").filter(|s| !s.is_null()).cloned();
    }

    let mut tally = Tally::default();
    let today = tally.today().to_string();
    let rows = opencode_rows(&db).ok()?;
    for (prefix, session_id, raw, row_type) in rows {
        let Ok(Value::Object(entry)) = serde_json::from_slice::<Value>(&raw) else { continue };
        let empty = Map::new();
        let (role, provider, model_id) = match &row_type {
            None => (text(entry.get("role")), text(entry.get("providerID")), entry.get("modelID").cloned()),
            Some(kind) => {
                let info = match entry.get("model") {
                    Some(m) if truthy(Some(m)) => match m.as_object() {
                        Some(m) => m,
                        None => continue,
                    },
                    _ => &empty,
                };
                (kind.clone(), text(info.get("providerID")), info.get("id").cloned())
            }
        };
        // Exact match: opencode provider ids are free-form, and a custom
        // "anthropic-proxy" gateway is not this subscription.
        if role != "assistant" || provider != "anthropic" {
            continue;
        }
        let Some((tokens, created)) = opencode_tokens(&entry) else { continue };
        if tokens.total() <= 0 {
            continue;
        }
        let day = if created > 0 {
            Local.timestamp_millis_opt(created).single().map(|at| day_string(at.date_naive())).unwrap_or_else(|| today.clone())
        } else {
            today.clone()
        };
        let model = text(model_id.as_ref().filter(|m| truthy(Some(m))).or(Some(&json!("claude"))));
        let model = model.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
        tally.add(&day, &format!("{prefix}{session_id}"), &model, tokens, 1);
    }

    let stats = if tally.prompts > 0 { tally.json() } else { Value::Null };
    let _ = write_json(&cache_file, &json!({"stats": stats}), 0o644, true);
    Some(stats).filter(|s| !s.is_null())
}

/// An opencode message's tokens, thinking counted as output since both are
/// generated, and when it was made
pub fn opencode_tokens(entry: &Map<String, Value>) -> Option<(Bucket, i64)> {
    let empty = Map::new();
    let tokens = match entry.get("tokens") {
        Some(t) if truthy(Some(t)) => t.as_object()?,
        _ => &empty,
    };
    let cache = match tokens.get("cache") {
        Some(c) if truthy(Some(c)) => c.as_object()?,
        _ => &empty,
    };
    let bucket = Bucket {
        input: number(tokens.get("input")),
        output: number(tokens.get("output")) + number(tokens.get("reasoning")),
        cache_read: number(cache.get("read")),
        cache_write: number(cache.get("write")),
    };
    let time = match entry.get("time") {
        Some(t) if truthy(Some(t)) => t.as_object()?,
        _ => &empty,
    };
    Some((bucket, number(time.get("created"))))
}

/// Every message row of opencode's database: v1 keeps messages in `message`,
/// with the role, provider and model in each row's data. v2 writes
/// `session_message` instead: the role moves to the `type` column and the
/// provider and model nest under data.model. A database can hold either or
/// both.
pub fn opencode_rows(db: &Path) -> rusqlite::Result<Vec<(&'static str, String, Vec<u8>, Option<String>)>> {
    use rusqlite::types::ValueRef;
    // Read-only: opencode may be writing right now
    let conn = rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    conn.busy_timeout(Duration::from_secs(2))?;
    conn.execute_batch("PRAGMA query_only = ON")?;
    let tables: HashSet<String> =
        conn.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")?.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<_, _>>()?;
    let mut queries = Vec::new();
    if tables.contains("message") {
        queries.push(("opencode:", "SELECT session_id, data, NULL FROM message"));
    }
    if tables.contains("session_message") {
        queries.push(("opencode-v2:", "SELECT session_id, data, type FROM session_message"));
    }
    let as_text = |value: ValueRef| -> String {
        match value {
            ValueRef::Null => "None".into(),
            ValueRef::Integer(i) => i.to_string(),
            ValueRef::Real(f) => f.to_string(),
            ValueRef::Text(t) | ValueRef::Blob(t) => String::from_utf8_lossy(t).into_owned(),
        }
    };
    let mut rows = Vec::new();
    for (prefix, query) in queries {
        let mut statement = conn.prepare(query)?;
        let mut cursor = statement.query([])?;
        while let Some(row) = cursor.next()? {
            let session = as_text(row.get_ref(0)?);
            let data = match row.get_ref(1)? {
                ValueRef::Text(t) | ValueRef::Blob(t) => t.to_vec(),
                _ => Vec::new(),
            };
            let kind = match row.get_ref(2)? {
                ValueRef::Null => None,
                other => Some(as_text(other)),
            };
            rows.push((prefix, session, data, kind));
        }
    }
    Ok(rows)
}

// ----------------------------------------------------------------- limits

struct Login {
    token: String,
    expires_at_ms: i64,
    refresh_expires_at_ms: i64,
    plan: String,
}

/// The access token, its expiry, and the display-safe plan label from the
/// CLI's login. Nothing else leaves the credential store: the token goes
/// nowhere but the Authorization header of the limits probe, and only the
/// plan label may travel into the printed record.
fn oauth_login(claude_dir: &Path) -> Login {
    let none = Login { token: String::new(), expires_at_ms: 0, refresh_expires_at_ms: 0, plan: String::new() };
    let Some(data) = read_json(&claude_dir.join(".credentials.json")) else { return none };
    let Some(login) = data.get("claudeAiOauth").and_then(Value::as_object) else { return none };
    // The profile's tier is asked first, but only one that names a
    // multiplier outranks the credentials'. The subscription still leads the
    // label, so a Team seat keeps reading Team.
    let mut tier = profile_tier(claude_dir);
    if max_multiplier(&tier).is_none() {
        tier = text(login.get("rateLimitTier"));
    }
    Login {
        token: text(login.get("accessToken")),
        expires_at_ms: number(login.get("expiresAt")),
        refresh_expires_at_ms: number(login.get("refreshTokenExpiresAt")),
        plan: plan_label(&tier, &text(login.get("subscriptionType"))),
    }
}

/// The credentials carry the tier their token was minted with, and an
/// upgrade does not restamp it: a refresh rewrites the file and keeps the old
/// value, so an account moved to Max 20x keeps reading Max 5x. The CLI's own
/// profile is refreshed against the account, so the tier it states there is
/// asked first.
fn profile_tier(claude_dir: &Path) -> String {
    let Some(profile) = read_json(&profile_path(claude_dir)) else { return String::new() };
    let Some(account) = profile.get("oauthAccount").and_then(Value::as_object) else { return String::new() };
    // A seat with no tier of its own is limited by its organization, which
    // is the shape a personal Max subscription takes.
    ["userRateLimitTier", "organizationRateLimitTier"].iter().map(|key| text(account.get(*key))).find(|tier| !tier.is_empty()).unwrap_or_default()
}

/// The CLI's profile for a config home: a legacy .config.json inside it,
/// else ~/.claude.json for the default home and <home>/.claude.json for one
/// it was pointed at with CLAUDE_CONFIG_DIR. A copy anywhere else is never
/// refreshed, and another home's profile describes another account.
fn profile_path(dir: &Path) -> PathBuf {
    let legacy = dir.join(".config.json");
    if legacy.exists() {
        return legacy;
    }
    let configured = std::env::var("CLAUDE_CONFIG_DIR").unwrap_or_default();
    if dir == expand_path("~/.claude") && !(!configured.is_empty() && expand_path(&configured) == dir) {
        return home().join(".claude.json");
    }
    dir.join(".claude.json")
}

/// The NNx of a tier like default_claude_max_20x, in the case it was written
fn max_multiplier(tier: &str) -> Option<String> {
    let lower = tier.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = lower[from..].find("max_") {
        let start = from + at + 4;
        let digits = lower[start..].chars().take_while(char::is_ascii_digit).count();
        if digits > 0 && lower[start + digits..].starts_with('x') {
            return Some(tier[start..start + digits + 1].to_string());
        }
        from = start;
    }
    None
}

/// The rate-limit tier names the ceiling, not the plan: a Team premium seat
/// runs on `default_claude_max_5x` while paying for Team. Lead with the
/// subscription and keep the multiplier as its qualifier, so Max still reads
/// "Max 5x" and a Team seat reads "Team 5x" rather than passing as Max.
fn plan_label(tier: &str, subscription: &str) -> String {
    let mut chars = subscription.chars();
    let plan = match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    };
    match max_multiplier(tier) {
        Some(multiplier) => format!("{} {multiplier}", if plan.is_empty() { "Max" } else { &plan }),
        None => plan,
    }
}

fn parse_utilization(value: Option<&Value>) -> f64 {
    let raw = match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return f64::NAN,
    };
    raw.trim().replace('%', "").trim().parse::<f64>().unwrap_or(f64::NAN)
}

fn normalize_utilization(value: Option<&Value>, percent_scale: bool) -> f64 {
    let n = parse_utilization(value);
    if !(n >= 0.0) {
        return -1.0;
    }
    // Anthropic's OAuth usage endpoint currently reports percentages (for
    // example 37.0 or 1.0). Older payloads sometimes used fractions (0.37).
    // A payload containing any value >= 1 is percent-scaled, so 1.0 renders
    // as 1%, not 100%.
    if percent_scale || n > 1.0 { (n / 100.0).min(1.0) } else { n.min(1.0) }
}

fn normalize_reset_at(value: Option<&Value>) -> String {
    let raw = match value {
        None | Some(Value::Null) => return String::new(),
        Some(Value::String(s)) => s.trim().to_string(),
        Some(other) => other.to_string(),
    };
    if raw.is_empty() {
        return raw;
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        let Ok(mut ms) = raw.parse::<i64>() else { return raw };
        if (ms as f64) < 1e12 {
            ms = ms.saturating_mul(1000);
        }
        return match Utc.timestamp_millis_opt(ms).single() {
            Some(at) if at.timestamp() < 253_402_300_800 => iso(&at),
            _ => raw,
        };
    }
    match parse_iso(&raw) {
        Some(Parsed::Aware(at)) => iso(&at),
        Some(Parsed::Naive(at)) => iso_naive(&at),
        None => raw,
    }
}

fn iso_naive(at: &chrono::NaiveDateTime) -> String {
    let micros = at.and_utc().timestamp_subsec_micros();
    let fraction = if micros > 0 { format!(".{micros:06}") } else { String::new() };
    format!("{}{fraction}", at.format("%Y-%m-%dT%H:%M:%S"))
}

/// An entry's `kind` names its window the way the flat buckets' keys do
/// ("weekly_scoped", "five_hour_scoped"). The panel reads a window out of
/// free text, which cannot survive a model name like "Opus 5 (1M context)",
/// where the "1M" reads as a one-minute window, so the window is settled here
/// instead and travels as an explicit title. It is capitalized the way the
/// flat windows title themselves, so "Fable Weekly" sits beside "Weekly"
/// rather than under it.
fn scoped_window(kind: &str) -> &'static str {
    let lower = kind.to_lowercase();
    if lower.contains("month") {
        "Monthly"
    } else if lower.contains("week") || lower.contains("day") {
        "Weekly"
    } else if lower.contains("hour") || lower.contains("session") {
        "Session"
    } else {
        ""
    }
}

/// Alongside the flat buckets, the payload carries a `limits` array, and
/// that array is the only place a model-scoped allowance shows up: a weekly
/// window that only one model draws from, say. The matching legacy keys
/// (`seven_day_opus`, `seven_day_sonnet`, ...) stayed behind at null, so a
/// collector that reads buckets alone silently drops a limit the account is
/// actually spending against. A model can hold more than one scoped window,
/// and only the pair of model and window tells them apart, so both make the
/// title and both make the key that keeps a repeat out.
fn scoped_limits(payload: &Value, percent_scale: bool) -> Vec<Value> {
    let Some(entries) = payload.get("limits").and_then(Value::as_array) else { return vec![] };
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for entry in entries.iter().filter(|e| e.is_object()) {
        let Some(model) = entry.get("scope").and_then(|s| s.get("model")).filter(|m| m.is_object()) else { continue };
        // A display name is what the panel wants, but an entry carrying only
        // an id still names a window worth showing.
        let name = text([model.get("display_name"), model.get("id")].into_iter().find(|v| truthy(*v)).flatten()).trim().to_string();
        let kind = text(entry.get("kind")).trim().to_string();
        if name.is_empty() || seen.contains(&(name.clone(), kind.clone())) {
            continue;
        }
        let percent = normalize_utilization(entry.get("percent"), percent_scale);
        if percent < 0.0 {
            continue;
        }
        let window = scoped_window(&kind);
        let title = if window.is_empty() { name.clone() } else { format!("{name} {window}") };
        seen.insert((name, kind));
        out.push(json!({"label": title, "title": title, "percent": percent, "resetsAt": normalize_reset_at(entry.get("resets_at"))}));
    }
    out
}

#[derive(Debug)]
enum Probe {
    Ok(Vec<Value>),
    Failed { help: String, transport: bool },
}

fn probe_limits(token: &str) -> Probe {
    let response = ureq::get(USAGE_ENDPOINT)
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-beta", "oauth-2025-04-20")
        .set("Accept", "application/json")
        .timeout(Duration::from_secs(10))
        .call();
    let payload = match response {
        Ok(response) => response.into_string().ok().and_then(|body| serde_json::from_str::<Value>(&body).ok()),
        Err(ureq::Error::Status(code, response)) => {
            let help = if code == 429 {
                let retry = response.header("retry-after").unwrap_or("").to_string();
                let after = if retry.is_empty() { String::new() } else { format!(" (retry after {retry}s)") };
                format!("Anthropic's usage endpoint is rate limiting checks right now{after}. Local Claude Code stats are still shown.")
            } else {
                format!("Anthropic's usage endpoint returned status {code}. Local Claude Code stats are still shown.")
            };
            return Probe::Failed { help, transport: false };
        }
        Err(_) => None,
    };
    // A transport failure reached no server at all: no route, no DNS. Any
    // real answer, including an error status, is a server we should stop
    // pestering; this is not.
    match payload {
        Some(payload) => limits_from_payload(&payload),
        None => Probe::Failed {
            help: "Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown.".into(),
            transport: true,
        },
    }
}

fn limits_from_payload(payload: &Value) -> Probe {
    let bucket = |key: &str| payload.get(key).filter(|b| b.is_object());
    let weekly = bucket("seven_day_oauth_apps").filter(|b| truthy(Some(b))).or_else(|| bucket("seven_day"));
    let session = bucket("five_hour");
    // One payload speaks one convention, so the scoped entries settle the
    // scale alongside the buckets rather than assuming their own.
    let mut raw = vec![session.and_then(|s| s.get("utilization")), weekly.and_then(|w| w.get("utilization"))];
    if let Some(entries) = payload.get("limits").and_then(Value::as_array) {
        raw.extend(entries.iter().filter(|e| e.is_object()).map(|e| e.get("percent")));
    }
    let percent_scale = raw.into_iter().any(|v| parse_utilization(v) >= 1.0);

    let mut limits = Vec::new();
    for (bucket, label) in [(session, "Session (5-hour)"), (weekly, "Weekly (7-day)")] {
        if let Some(bucket) = bucket {
            let percent = normalize_utilization(bucket.get("utilization"), percent_scale);
            if percent >= 0.0 {
                limits.push(json!({"label": label, "percent": percent, "resetsAt": normalize_reset_at(bucket.get("resets_at"))}));
            }
        }
    }
    limits.extend(scoped_limits(payload, percent_scale));
    if limits.is_empty() {
        return Probe::Failed { help: "Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown.".into(), transport: false };
    }
    Probe::Ok(limits)
}

/// Cached windows reset to zero when their measured period ends. Without a
/// fresh probe, the next rolling window has no known reset time yet.
fn usable_cached_limits(cached: &Value) -> Vec<Value> {
    let now = Utc::now();
    let open = |entry: &Value| -> bool {
        let raw = text(entry.get("resetsAt"));
        if raw.is_empty() {
            return true;
        }
        super::parse_utc(&raw).is_none_or(|resets: DateTime<_>| resets > now)
    };
    cached
        .get("limits")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|e| e.is_object())
        .map(|entry| {
            if open(entry) {
                return entry.clone();
            }
            let mut entry = entry.clone();
            entry["percent"] = json!(0.0);
            entry["resetsAt"] = json!("");
            entry
        })
        .collect()
}

struct Limits {
    limits: Value,
    status: String,
    help: String,
    /// The numbers came from Anthropic just now (or within the reuse window)
    /// rather than from a cache kept past a failed or impossible probe
    live: bool,
    /// When the numbers were measured, so a stale account can say how old
    /// they are
    fetched_at: i64,
    retry: bool,
}

fn collect_limits(login: &Login, force: bool, cache_name: &str) -> Limits {
    // A panel that is opened and shut repeatedly must not turn into a
    // request per flick, so recent probe results are reused for a short
    // window, and kept as the answer of record when a later probe fails.
    // Every account keeps its own, so one account's allowance never stands in
    // for another's.
    let probe_cache = cache_root().join(cache_name);
    let cached = read_json(&probe_cache).unwrap_or(Value::Null);
    let fallback = usable_cached_limits(&cached);
    let mut result = Limits { limits: json!([]), status: String::new(), help: AUTH_HELP.into(), live: false, fetched_at: number(cached.get("fetchedAtMs")), retry: false };
    let now = now_ms() as f64;

    // Probing needs a live token and only the Claude Code CLI can mint one:
    // it refreshes the credential file when it runs, so a machine left alone
    // long enough finds the saved token lapsed. Say so, and keep showing the
    // last numbers, resetting elapsed windows to zero.
    if login.token.is_empty() {
        result.limits = json!(fallback);
        result.status = "Waiting for auth".into();
        return result;
    }
    if login.expires_at_ms > 0 && (login.expires_at_ms as f64) <= now {
        let showing = if fallback.is_empty() { "." } else { " \u{2014} showing the last known limits." };
        result.limits = json!(fallback);
        // A lapsed access token is routine, not a sign-out: it lives about
        // eight hours, and the CLI mints a new one from the refresh token the
        // next time it runs. Only a lapsed refresh token is a sign-in a person
        // must redo.
        if (login.refresh_expires_at_ms as f64) > now {
            result.status = "Limits paused".into();
            result.help = format!("Claude Code's access token has lapsed{showing} Start Claude Code to refresh it; signing in again is not needed.");
        } else {
            result.status = "Sign-in expired".into();
            result.help = format!("Claude Code's saved sign-in expired{showing} Start Claude Code, or run `claude auth login`, to refresh it.");
        }
        return result;
    }

    // --force is a person asking for fresh numbers, so it skips the reuse
    // window entirely; the interval is there to absorb repeated panel opens,
    // not to overrule someone who pressed refresh.
    let fetched_age = now_secs() - result.fetched_at as f64 / 1000.0;
    if !fallback.is_empty() && !force && (0.0..PROBE_MIN_INTERVAL_SECONDS).contains(&fetched_age) {
        result.limits = json!(fallback);
        result.live = true;
        result.help.clear();
        return result;
    }

    match probe_limits(&login.token) {
        Probe::Ok(limits) => {
            result.limits = json!(limits);
            result.live = true;
            result.help.clear();
            result.fetched_at = now_ms();
            let _ = write_json(&probe_cache, &sorted(&json!({"fetchedAtMs": result.fetched_at, "limits": result.limits})), 0o644, true);
        }
        Probe::Failed { help, transport } => {
            // The first probe after login often fires before DHCP has handed
            // out a route. Ask the shell to try again sooner than its regular
            // interval.
            result.retry = transport;
            if fallback.is_empty() {
                result.status = "Claude limits unavailable".into();
                result.help = help;
            } else {
                result.limits = json!(fallback);
                let age = now_secs() - result.fetched_at as f64 / 1000.0;
                result.live = (0.0..CURRENT_ENOUGH_SECONDS).contains(&age);
            }
        }
    }
    result
}

// --------------------------------------------------------------- accounts

fn current_account_id(dir: &Path) -> String {
    let profile = read_json(&profile_path(dir)).unwrap_or(Value::Null);
    text(profile.get("oauthAccount").and_then(|a| a.get("accountUuid")))
}

fn account_limits(account: &Map<String, Value>, force: bool) -> Value {
    let id = text(account.get("id"));
    let dir = if truthy(account.get("home")) { expand_path(&text(account.get("home"))) } else { expand_path("~/.claude") };
    let login = oauth_login(&dir);
    // Keyed by the subscription, not the label: forget "Work" and add a
    // different "Work", and the new one must never fall back on the old one's
    // allowance. Who the home is signed in as now, not when it was added: a
    // `claude auth login` run in it by hand makes it a different
    // subscription.
    let identity = current_account_id(&dir);
    let key = super::safe_key(&if identity.is_empty() { text(account.get("accountId")) } else { identity.clone() });
    let key = if key.is_empty() { id.clone() } else { key };
    // The primary home is keyed the same way once it says who it's signed in
    // as, so signing it in to another subscription never inherits the last
    // one's numbers; until then it keeps the single-account cache.
    let cache_name = if truthy(account.get("primary")) && identity.is_empty() { "claude-limits.json".to_string() } else { format!("claude-limits-{key}.json") };
    let limits = collect_limits(&login, force, &cache_name);
    let label = text(account.get("label"));
    json!({
        "id": account["id"],
        "label": if label.is_empty() { id } else { label },
        "email": text(account.get("email")),
        "plan": if login.plan.is_empty() { text(account.get("plan")) } else { login.plan.clone() },
        "active": account["active"],
        "primary": truthy(account.get("primary")),
        "limits": limits.limits,
        "stale": !limits.live,
        "fetchedAt": limits.fetched_at,
        "usageStatusText": limits.status,
        "authHelpText": limits.help,
        "retryAdvised": limits.retry,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the Python collector made of each payload
    #[test]
    fn payloads_read_as_python_read_them() {
        let cases: Vec<Value> = serde_json::from_str(include_str!("testdata/claude-probe.json")).unwrap();
        for case in cases {
            let expected = &case["probe"];
            match limits_from_payload(&case["payload"]) {
                Probe::Ok(limits) => assert_eq!(json!({"ok": true, "limits": limits}), *expected),
                Probe::Failed { help, .. } => assert_eq!(json!({"ok": false, "helpText": help}), *expected),
            }
        }
    }

    #[test]
    fn plans_lead_with_the_subscription() {
        assert_eq!(plan_label("default_claude_max_5x", "team"), "Team 5x");
        assert_eq!(plan_label("x_MAX_20X", ""), "Max 20X");
        assert_eq!(plan_label("max_x_max_3x", "pro"), "Pro 3x");
        assert_eq!(plan_label("", "pro"), "Pro");
    }
}
