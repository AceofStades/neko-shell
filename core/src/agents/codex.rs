//! Codex usage as one display-ready JSON record.
//!
//! Local stats come from native Codex CLI session files, pi/omp sessions that
//! ran through openai-codex, and opencode sessions that ran on an OpenAI
//! provider; rate limits and the plan come from the Codex app-server RPC. The
//! agents panel only ever reads the JSON this prints.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::time::{Duration, Instant};

use chrono::{TimeZone, Utc};
use serde_json::{json, Map, Value};

use super::{cache_root, day_string, home, int, iso, local_day, now_secs, read_fresh_json, read_json, sha1_hex, text, truthy, write_json, Bucket, Tally};

const AUTH_HELP: &str = "Run `codex login` to authenticate.";

// session_meta.model_provider for the built-in OpenAI backend, which is the
// only one this subscription pays for. Any other id points somewhere else:
// `--oss`'s ollama or lmstudio, or a custom provider in config.toml.
const NATIVE_PROVIDER: &str = "openai";

// A scan this recent is only reused to dedup concurrent collector runs (the
// update command backgrounds one per agent while the panel refreshes on its
// own); every periodic widget refresh lands a real rescan. --limits-only
// promises only fresh limits, so it may reuse a scan for up to 15 minutes.
const SCAN_REUSE_SECONDS: f64 = 20.0;
const LIMITS_ONLY_REUSE_SECONDS: f64 = 900.0;

// Per-file totals of native Codex sessions survive between runs, so a rescan
// only reads the session files that changed. The Python collector wrote
// schema 1 to the same file; either one reads only its own.
const FILE_CACHE_SCHEMA: i64 = 2;

pub fn run(args: &[String]) -> Result<(), String> {
    // --force rescans everything and rewrites the cache. --limits-only is for
    // the panel's refreshLimits() call: only the limits probe must be fresh,
    // so it may reuse a scan for far longer than a normal run.
    let flags = super::flags(args, &[])?;
    let max_age = if flags.force { 0.0 } else if flags.limits_only { LIMITS_ONLY_REUSE_SECONDS } else { SCAN_REUSE_SECONDS };
    let stats = cached_local_stats(max_age);

    let registered = super::registered_accounts("codex");
    let accounts: Vec<Value> = registered.iter().map(account_limits).collect();
    let current = accounts.iter().find(|a| a["active"] == json!(true));
    let rpc = match current {
        // The top-level fields keep describing the account new sessions use
        Some(current) => {
            let mut rpc = json!({
                "limits": current["limits"],
                "tierLabel": current["plan"],
                "usageStatusText": current["usageStatusText"],
                "authHelpText": current["authHelpText"],
            });
            if truthy(current.get("resetCredits")) {
                rpc["resetCredits"] = current["resetCredits"].clone();
            }
            rpc
        }
        None => fetch_codex_rpc(None),
    };

    let mut record = json!({
        "schemaVersion": 1,
        "id": "codex",
        "name": "Codex",
        "updatedAt": super::iso_now_utc(),
        "ready": true,
        "hasLocalStats": true,
    });
    let map = record.as_object_mut().unwrap();
    for part in [stats, rpc] {
        if let Value::Object(part) = part {
            map.extend(part);
        }
    }
    if !accounts.is_empty() {
        map.insert("accountSwitch".into(), registered[0]["switch"].clone());
        map.insert("accounts".into(), Value::Array(accounts));
    }
    super::print_compact(&record);
    Ok(())
}

fn model_name(raw: Option<&Value>) -> String {
    let name = text(raw);
    if name.is_empty() { "codex".into() } else { name }
}

/// PATH with the places a Codex install lands added, for finding codex and
/// for running it
fn runtime_path() -> String {
    let home = home().display().to_string();
    [std::env::var("PATH").unwrap_or_default(), format!("{home}/.local/bin"), format!("{home}/.npm-global/bin"), format!("{home}/.local/share/mise/shims")]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(":")
}

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|m| m.is_file()) && unsafe { libc::access(std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap_or_default().as_ptr(), libc::X_OK) == 0 }
}

fn find_command(name: &str) -> Option<PathBuf> {
    runtime_path().split(':').map(|dir| Path::new(dir).join(name)).find(|candidate| executable(candidate))
}

fn mise_shims_dir() -> PathBuf {
    let data = std::env::var("MISE_DATA_DIR").ok().filter(|d| !d.is_empty()).map(PathBuf::from).unwrap_or_else(|| super::xdg("XDG_DATA_HOME", ".local/share").join("mise"));
    data.join("shims")
}

/// neko-mise-install writes a regular file whose first step is `mise use
/// -g`, and mise's shims exec `mise x`; running either installs the tool it
/// wraps. A shim is a symlink to the mise binary itself, so the symlink check
/// comes after the shim checks: a symlink elsewhere is the user's own binary.
fn is_lazy_launcher(path: &Path) -> bool {
    let absolute = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().unwrap_or_default().join(path) };
    if absolute.parent() == Some(mise_shims_dir().as_path()) {
        return true;
    }
    if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return find_command("mise").is_some_and(|mise| super::resolve(path) == super::resolve(&mise));
    }
    let mut head = Vec::new();
    match File::open(path) {
        Ok(file) => {
            let _ = file.take(4096).read_to_end(&mut head);
            super::bytes_contain(&head, b"mise use") || super::bytes_contain(&head, b"mise x ")
        }
        Err(_) => false,
    }
}

fn find_codex_binary() -> Option<PathBuf> {
    for dir in runtime_path().split(':') {
        let candidate = Path::new(dir).join("codex");
        if executable(&candidate) && !is_lazy_launcher(&candidate) {
            return Some(candidate);
        }
    }
    // `mise which` only prints a binary that is already installed, so it is
    // the safe way to resolve a codex managed by mise without running the
    // launcher. It can resolve a configured `latest` over the network; the
    // usage probe stays offline.
    let mise = find_command("mise")?;
    let mut child = Command::new(mise)
        .args(["which", "codex"])
        .env("PATH", runtime_path())
        .env("MISE_OFFLINE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let mut out = String::new();
    child.stdout.take()?.read_to_string(&mut out).ok()?;
    let resolved = PathBuf::from(out.trim());
    (status.success() && resolved.is_file() && !is_lazy_launcher(&resolved)).then_some(resolved)
}

// ------------------------------------------------------------------ stats

/// One session file's totals, the unit the file cache stores: day -> model
/// -> [input, output, cacheRead, cacheWrite, prompts]. Day-keyed and with no
/// "today" in it, so a record stays true however long it is kept. `mtime` is
/// None for a file read only in part, which the cache refuses.
#[derive(Clone)]
struct FileRecord {
    mtime: Option<i64>,
    size: u64,
    days: BTreeMap<String, Vec<(String, [i64; 5])>>,
}

impl FileRecord {
    fn record(&mut self, day: &str, model: &str, tokens: Bucket) {
        let models = self.days.entry(day.to_string()).or_default();
        let index = match models.iter().position(|(name, _)| name == model) {
            Some(index) => index,
            None => {
                models.push((model.to_string(), [0; 5]));
                models.len() - 1
            }
        };
        let totals = &mut models[index].1;
        totals[0] += tokens.input;
        totals[1] += tokens.output;
        totals[2] += tokens.cache_read;
        totals[3] += tokens.cache_write;
        totals[4] += 1;
    }

    /// Folds the totals, freshly read or replayed from cache, into the run
    fn merge_into(&self, session: &str, tally: &mut Tally) {
        for (day, models) in &self.days {
            for (model, t) in models {
                tally.add(day, session, model, Bucket { input: t[0], output: t[1], cache_read: t[2], cache_write: t[3] }, t[4]);
            }
        }
    }

    fn json(&self) -> Value {
        let days: Map<String, Value> = self
            .days
            .iter()
            .map(|(day, models)| (day.clone(), Value::Object(models.iter().map(|(model, t)| (model.clone(), json!(t))).collect())))
            .collect();
        json!({"mtime": self.mtime, "size": self.size, "days": days})
    }

    fn from_json(value: &Value) -> Option<FileRecord> {
        let mut days = BTreeMap::new();
        for (day, models) in value.get("days")?.as_object()? {
            let mut list = Vec::new();
            for (model, totals) in models.as_object()? {
                let totals = totals.as_array()?;
                if totals.len() != 5 {
                    return None;
                }
                let mut counts = [0; 5];
                for (slot, n) in counts.iter_mut().zip(totals) {
                    *slot = n.as_i64()?;
                }
                list.push((model.clone(), counts));
            }
            days.insert(day.clone(), list);
        }
        Some(FileRecord { mtime: Some(value.get("mtime")?.as_i64()?), size: value.get("size")?.as_u64()?, days })
    }
}

fn add_usage(tally: &mut Tally, day: &str, session: &str, model: &str, tokens: Bucket) {
    tally.add(day, session, model, tokens, 1);
}

fn pi_parent_session(path: &Path) -> Option<PathBuf> {
    let file = File::open(path).ok()?;
    let mut first = Vec::new();
    let mut reader = std::io::BufReader::new(file);
    std::io::BufRead::read_until(&mut reader, b'\n', &mut first).ok()?;
    let header: Value = serde_json::from_str(&String::from_utf8_lossy(&first)).ok()?;
    let parent = header.get("parentSession")?.as_str().filter(|p| !p.is_empty())?;
    Some(absolute(&super::expand_user(parent)))
}

/// A path made absolute and tidied the way os.path.abspath does, without
/// resolving symlinks
fn absolute(path: &Path) -> PathBuf {
    let joined = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().unwrap_or_default().join(path) };
    let mut out = PathBuf::from("/");
    for part in joined.components() {
        match part {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::Normal(name) => out.push(name),
            _ => {}
        }
    }
    out
}

/// Whether a line holds "provider": "openai-codex" or "api": "openai-codex...
fn names_openai_codex(line: &str) -> bool {
    let after_key = |key: &str, exact: bool| {
        line.match_indices(key).any(|(at, _)| {
            let rest = line[at + key.len()..].trim_start();
            let Some(rest) = rest.strip_prefix(':') else { return false };
            let rest = rest.trim_start();
            if exact { rest.starts_with("\"openai-codex\"") } else { rest.starts_with("\"openai-codex") }
        })
    };
    after_key("\"provider\"", true) || after_key("\"api\"", false)
}

/// Every pi and omp message that ran through openai-codex. A forked session
/// repeats its parent's messages, so each message counts once, and a session
/// counts only for the messages it doesn't share with its ancestors.
fn scan_pi_sessions(tally: &mut Tally) {
    let today = tally.today().to_string();
    let mut seen: HashSet<(bool, String, String)> = HashSet::new();
    let mut session_keys: HashMap<PathBuf, HashSet<(bool, String, String)>> = HashMap::new();
    let mut today_keys: HashMap<PathBuf, HashSet<(bool, String, String)>> = HashMap::new();
    let mut order: Vec<PathBuf> = Vec::new();

    for root in super::pi_session_roots() {
        if !root.exists() {
            continue;
        }
        // Every file, as a search of the tree would read them, hidden ones
        // aside
        for path in super::files_under(&root, "", true) {
            if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
                continue;
            }
            let Ok(bytes) = fs::read(&path) else { continue };
            if bytes.contains(&0) {
                continue;
            }
            let path = absolute(&path);
            let content = String::from_utf8_lossy(&bytes);
            for line in content.lines() {
                if !names_openai_codex(line) {
                    continue;
                }
                let Ok(Value::Object(entry)) = serde_json::from_str::<Value>(line) else { continue };
                if entry.get("type").and_then(Value::as_str) != Some("message") {
                    continue;
                }
                let id = text(entry.get("id"));
                let stamp = text(entry.get("timestamp"));
                // Forks retain both fields; ids alone can collide across
                // sessions
                let key = if !id.is_empty() && !stamp.is_empty() { (true, id, stamp) } else { (false, path.to_string_lossy().to_string(), id) };
                let duplicate = !seen.insert(key.clone());
                let empty = Map::new();
                let message = match entry.get("message") {
                    Some(m) if truthy(Some(m)) => match m.as_object() {
                        Some(m) => m,
                        None => continue,
                    },
                    _ => &empty,
                };
                if message.get("role").and_then(Value::as_str) != Some("assistant") {
                    continue;
                }
                if text(message.get("provider")) != "openai-codex" && !text(message.get("api")).starts_with("openai-codex") {
                    continue;
                }
                let Some(usage) = message.get("usage").filter(|u| truthy(Some(u))).and_then(Value::as_object) else { continue };
                let total = int(usage.get("totalTokens"));
                let mut tokens = Bucket { input: int(usage.get("input")), output: int(usage.get("output")), cache_read: int(usage.get("cacheRead")), cache_write: int(usage.get("cacheWrite")) };
                let none = |t: &Bucket| t.input == 0 && t.output == 0 && t.cache_read == 0 && t.cache_write == 0;
                if total != 0 && none(&tokens) {
                    tokens.input = total;
                }
                if none(&tokens) {
                    continue;
                }
                let day = local_day(if truthy(entry.get("timestamp")) { entry.get("timestamp") } else { message.get("timestamp") });
                if !session_keys.contains_key(&path) {
                    order.push(path.clone());
                }
                session_keys.entry(path.clone()).or_default().insert(key.clone());
                if day == today {
                    today_keys.entry(path.clone()).or_default().insert(key);
                }
                if duplicate {
                    continue;
                }
                add_usage(tally, &day, &path.to_string_lossy(), &model_name(message.get("model")), tokens);
            }
        }
    }

    // Session ownership, settled once every file is read so the order they
    // were read in can't affect it
    let parents: HashMap<&PathBuf, Option<PathBuf>> = order.iter().map(|path| (path, pi_parent_session(path))).collect();
    for path in &order {
        tally.drop_session(&path.to_string_lossy());
    }
    for path in &order {
        let mut inherited = HashSet::new();
        let mut visited = HashSet::from([path.clone()]);
        let mut parent = parents.get(path).cloned().flatten();
        while let Some(current) = parent {
            if !visited.insert(current.clone()) {
                break;
            }
            inherited.extend(session_keys.get(&current).into_iter().flatten().cloned());
            parent = parents.get(&current).cloned().flatten();
        }
        let unique: Vec<_> = session_keys[path].iter().filter(|k| !inherited.contains(*k)).collect();
        if unique.is_empty() {
            continue;
        }
        let today_unique = today_keys.get(path).is_some_and(|keys| unique.iter().any(|k| keys.contains(*k)));
        tally.add_session(&path.to_string_lossy(), today_unique);
    }
}

/// A subscription burned entirely through opencode leaves no native session
/// files, but opencode records per-message provider, model, and token usage
/// in its own database. Whether the scan ran to completion: a scan cut short
/// by a database error still contributes what it read, but must not be
/// cached as if it were the whole story.
fn scan_opencode_sessions(tally: &mut Tally) -> bool {
    let db = super::opencode_db();
    if !db.is_file() {
        return true;
    }
    let mut rows = Vec::new();
    let read = (|| -> rusqlite::Result<()> {
        // Read-only: opencode may be writing right now
        let conn = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        conn.busy_timeout(Duration::from_secs(2))?;
        conn.execute_batch("PRAGMA query_only = ON")?;
        // opencode databases grow huge, so SQLite picks the rows out: the
        // LIKE gates skip what can't match without parsing it, and
        // json_valid guards json_extract, which raises on malformed JSON.
        let mut statement = conn.prepare(
            "SELECT session_id, data FROM message \
             WHERE data LIKE '%\"role\"%:%\"assistant\"%' \
             AND data LIKE '%\"providerID\"%:%\"openai\"%' \
             AND CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END = 'assistant' \
             AND CASE WHEN json_valid(data) THEN json_extract(data, '$.providerID') END = 'openai'",
        )?;
        let mut cursor = statement.query([])?;
        while let Some(row) = cursor.next()? {
            use rusqlite::types::ValueRef;
            let session = match row.get_ref(0)? {
                ValueRef::Null => "None".to_string(),
                ValueRef::Integer(i) => i.to_string(),
                ValueRef::Real(f) => f.to_string(),
                ValueRef::Text(t) | ValueRef::Blob(t) => String::from_utf8_lossy(t).into_owned(),
            };
            let data = match row.get_ref(1)? {
                ValueRef::Text(t) | ValueRef::Blob(t) => t.to_vec(),
                _ => Vec::new(),
            };
            rows.push((session, data));
        }
        Ok(())
    })();

    for (session, raw) in rows {
        let Ok(Value::Object(entry)) = serde_json::from_slice::<Value>(&raw) else { continue };
        // Exact match: opencode provider ids are free-form, and a custom
        // "openai-local" gateway is not this subscription
        if entry.get("role").and_then(Value::as_str) != Some("assistant") || text(entry.get("providerID")) != "openai" {
            continue;
        }
        let empty = Map::new();
        let object = |key: &str, from: &Map<String, Value>| -> Option<Map<String, Value>> {
            match from.get(key) {
                Some(v) if truthy(Some(v)) => v.as_object().cloned(),
                _ => Some(empty.clone()),
            }
        };
        let Some(tokens) = object("tokens", &entry) else { continue };
        let Some(cache) = object("cache", &tokens) else { continue };
        let Some(time) = object("time", &entry) else { continue };
        let bucket = Bucket {
            input: int(tokens.get("input")),
            // opencode keeps thinking tokens out of output; both are generated
            output: int(tokens.get("output")) + int(tokens.get("reasoning")),
            cache_read: int(cache.get("read")),
            cache_write: int(cache.get("write")),
        };
        if bucket.input == 0 && bucket.output == 0 && bucket.cache_read == 0 && bucket.cache_write == 0 {
            continue;
        }
        let day = local_day(time.get("created"));
        let model_id = text(entry.get("modelID"));
        let model = model_name(Some(&json!(model_id.trim_end_matches('/').rsplit('/').next().unwrap_or(""))));
        add_usage(tally, &day, &format!("opencode:{session}"), &model, bucket);
    }
    // Transient lock, schema migration, corruption: the numbers stop where
    // the error came, incomplete
    read.is_ok()
}

fn codex_home() -> PathBuf {
    super::env_or("CODEX_HOME", home().join(".codex"))
}

fn scan_native_codex_sessions(tally: &mut Tally, cached: &HashMap<String, FileRecord>, scanned: &mut Map<String, Value>) {
    let home = codex_home();
    let cutoff = now_secs() - 30.0 * 24.0 * 60.0 * 60.0;
    let mut files = Vec::new();
    for root in [home.join("sessions"), home.join("archived_sessions")] {
        if !root.exists() {
            continue;
        }
        for path in super::files_under(&root, ".jsonl", false) {
            let Ok(stat) = fs::metadata(&path) else { continue };
            let mtime = stat.mtime() as f64 + stat.mtime_nsec() as f64 / 1e9;
            if mtime >= cutoff {
                files.push((path, stat));
            }
        }
    }

    for (path, stat) in files {
        let key = path.to_string_lossy().to_string();
        let mtime = stat.mtime() * 1_000_000_000 + stat.mtime_nsec();
        let record = match cached.get(&key) {
            Some(record) if record.mtime == Some(mtime) && record.size == stat.size() => record.clone(),
            _ => read_native_codex_session(&path, &stat),
        };
        if record.mtime.is_some() {
            scanned.insert(key.clone(), record.json());
        }
        record.merge_into(&key, tally);
    }
}

/// A non-empty object, an empty one for anything empty, or None for a value
/// of another kind, where Python's .get() would have raised
fn object_or_empty(value: Option<&Value>) -> Option<Map<String, Value>> {
    match value {
        Some(v) if truthy(Some(v)) => v.as_object().cloned(),
        _ => Some(Map::new()),
    }
}

fn read_native_codex_session(path: &Path, stat: &fs::Metadata) -> FileRecord {
    let mtime = stat.mtime() * 1_000_000_000 + stat.mtime_nsec();
    let mut record = FileRecord { mtime: Some(mtime), size: stat.size(), days: BTreeMap::new() };
    let file_mtime = json!(stat.mtime() as f64 + stat.mtime_nsec() as f64 / 1e9);
    let Ok(bytes) = fs::read(path) else {
        record.mtime = None;
        return record;
    };
    let content = String::from_utf8_lossy(&bytes);
    let mut model = "codex".to_string();
    let mut seen_meta = false;
    let mut previous_total: Option<Value> = None;

    // A shape the reader can't follow ends the file there: what was read
    // counts, but the record isn't cached, so the rest isn't hidden until the
    // file changes
    let complete = (|| -> Option<()> {
        for raw in content.lines() {
            // A cheap filter before parsing keeps files of unrelated lines
            // cheap; session_meta still gets through, since it says which
            // provider served the rollout
            if !raw.contains("\"token_count\"") && !raw.contains("\"turn_context\"") && !raw.contains("\"session_meta\"") {
                continue;
            }
            let Ok(entry) = serde_json::from_str::<Value>(raw) else { continue };
            let entry = entry.as_object()?;
            let kind = entry.get("type").and_then(Value::as_str);
            if kind == Some("session_meta") {
                // A forked rollout copies its parent's session_meta after its
                // own, so only the first one, as Codex reads it, says who
                // served this
                if seen_meta {
                    continue;
                }
                seen_meta = true;
                // Codex CLI fronts any OpenAI-compatible backend (`--oss`, or
                // a custom model_provider). Those turns bill the local box or
                // a third party, never this subscription, so the whole
                // rollout is dropped. Rollouts predating the field carry no
                // provider at all, and count.
                let meta = object_or_empty(entry.get("payload"))?;
                let provider = text(meta.get("model_provider"));
                if !provider.is_empty() && provider != NATIVE_PROVIDER {
                    break;
                }
                continue;
            }
            if kind == Some("turn_context") {
                let payload = object_or_empty(entry.get("payload"))?;
                let named = [payload.get("model"), payload.get("model_slug")].into_iter().find(|v| truthy(*v)).flatten();
                if let Some(named) = named {
                    model = model_name(Some(named));
                }
                continue;
            }
            let entry_value = Value::Object(entry.clone());
            let mut payload = entry.get("payload").filter(|p| truthy(Some(p))).unwrap_or(&entry_value);
            if kind == Some("response_item") {
                if let Some(inner) = payload.as_object().and_then(|p| p.get("payload")).filter(|p| truthy(Some(p))) {
                    payload = inner;
                }
            }
            let Some(payload) = payload.as_object() else { continue };
            if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                continue;
            }
            let info = object_or_empty(payload.get("info"))?;
            // total_token_usage is cumulative for the session; adding every
            // snapshot makes usage grow quadratically, so count the last turn
            let usage = object_or_empty(info.get("last_token_usage"))?;
            let cache_read = int(usage.get("cached_input_tokens"));
            let cache_write = int(usage.get("cache_write_input_tokens"));
            // Cached tokens are included in input_tokens, and reasoning
            // tokens in output_tokens: keep the cache split without counting
            // either twice
            let tokens = Bucket { input: (int(usage.get("input_tokens")) - cache_read - cache_write).max(0), output: int(usage.get("output_tokens")), cache_read, cache_write };
            if tokens.input == 0 && tokens.output == 0 && tokens.cache_read == 0 && tokens.cache_write == 0 {
                continue;
            }
            // Quota updates can repeat the previous request's
            // last_token_usage. Only an unchanged cumulative snapshot proves
            // a repeat: separate requests may have identical last-token
            // counts, and older records may carry no cumulative counters.
            if let Some(total) = info.get("total_token_usage").filter(|t| t.as_object().is_some_and(|o| !o.is_empty())) {
                if previous_total.as_ref() == Some(total) {
                    continue;
                }
                previous_total = Some(total.clone());
            }
            let stamp = if truthy(entry.get("timestamp")) { entry.get("timestamp") } else { Some(&file_mtime) };
            record.record(&local_day(stamp), &model, tokens);
        }
        Some(())
    })();
    if complete.is_none() {
        record.mtime = None;
    }
    record
}

fn scan_cache_digest() -> String {
    // The digest covers every data path the scan reads: the codex session
    // roots, the opencode database, and (through the home) pi's and omp's
    let key = format!("{}\n{}\n{}", home().display(), codex_home().display(), super::opencode_db().display());
    sha1_hex(&key)[..16].to_string()
}

/// Per-file totals of native sessions from earlier scans, keyed by path.
/// Session files are append-only, so a file whose mtime and size both match
/// its record can't have grown a turn since, and its totals are replayed
/// instead of read. These records carry no "today" and never expire on their
/// own: only the file they describe or a change of timezone invalidates one.
/// pi and omp sessions stay out: a forked pi session repeats its parent's
/// messages, so they are only deduplicated across the whole tree at once.
fn read_file_cache(path: &Path) -> HashMap<String, FileRecord> {
    let Some(payload) = read_json(path) else { return HashMap::new() };
    if payload.get("schemaVersion").and_then(Value::as_i64) != Some(FILE_CACHE_SCHEMA) || payload.get("zone") != Some(&super::zone_signature()) {
        return HashMap::new();
    }
    payload
        .get("files")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .filter_map(|(path, record)| Some((path.clone(), FileRecord::from_json(record)?)))
        .collect()
}

/// The stats, a forced scan (no reuse at all) reading every session file
/// again, and whether the scan was complete
fn run_local_scans(max_age: f64) -> (Value, bool) {
    let cache_file = cache_root().join(format!("codex-files-{}.json", scan_cache_digest()));
    let cached = if max_age > 0.0 { read_file_cache(&cache_file) } else { HashMap::new() };
    let mut scanned = Map::new();
    let mut tally = Tally::default();
    scan_pi_sessions(&mut tally);
    scan_native_codex_sessions(&mut tally, &cached, &mut scanned);
    let complete = scan_opencode_sessions(&mut tally);
    // Only the files this scan saw are written back, so deleted sessions and
    // ones that aged out of the 30-day window leave the cache
    let payload = json!({"schemaVersion": FILE_CACHE_SCHEMA, "zone": super::zone_signature(), "files": scanned});
    if let Err(error) = write_json(&cache_file, &payload, 0o644, true) {
        eprintln!("neko-agent-usage-codex: could not write file cache ({error})");
    }
    (tally.json(), complete)
}

/// The cache is a versioned envelope around the stats, so a corrupted or
/// foreign-shaped file is a miss. today* fields only mean today on the day
/// they were scanned, so a cache from another local date is a miss too.
fn read_cached_stats(cache_file: &Path, max_age: f64) -> Option<Value> {
    let cached = read_fresh_json(cache_file, max_age)?;
    if cached.get("schemaVersion").and_then(Value::as_i64) != Some(2) || cached.get("scanDate").and_then(Value::as_str) != Some(&day_string(super::today())) {
        return None;
    }
    let stats = cached.get("stats").filter(|s| s.is_object())?;
    ["todayPrompts", "todayTotalTokens", "recentDays", "activeDates", "modelUsage"].iter().all(|k| stats.get(*k).is_some()).then(|| stats.clone())
}

/// Local stats, with the cache as a pure optimization: a cache that can't be
/// used degrades to a direct scan, never a failure
fn cached_local_stats(max_age: f64) -> Value {
    let digest = scan_cache_digest();
    let root = cache_root();
    let cache_file = root.join(format!("codex-scan-{digest}.json"));
    if let Some(cached) = read_cached_stats(&cache_file, max_age) {
        return cached;
    }
    let _lock = match super::lock(&root.join(format!("codex-scan-{digest}.lock"))) {
        Ok(lock) => lock,
        Err(error) => {
            eprintln!("neko-agent-usage-codex: cache unavailable ({error}); scanning directly");
            return run_local_scans(max_age).0;
        }
    };
    if let Some(cached) = read_cached_stats(&cache_file, max_age) {
        return cached;
    }
    let (stats, complete) = run_local_scans(max_age);
    // An interrupted scan still serves this run, but caching it would hide
    // the missing usage from every reader until the cache expires
    if complete {
        let payload = json!({"schemaVersion": 2, "scanDate": day_string(super::today()), "stats": stats});
        if let Err(error) = write_json(&cache_file, &payload, 0o644, true) {
            eprintln!("neko-agent-usage-codex: could not write usage cache ({error})");
        }
    }
    stats
}

// -------------------------------------------------------------------- RPC

enum RpcError {
    /// The app-server is gone, or never answered
    Failed(String),
    /// It's up but said nothing in time
    Timeout(String),
}

impl RpcError {
    fn message(&self) -> &str {
        match self {
            RpcError::Failed(m) | RpcError::Timeout(m) => m,
        }
    }
}

struct AppServer {
    child: Child,
    stdin: Option<ChildStdin>,
    pending: Vec<u8>,
}

impl AppServer {
    fn send(&mut self, payload: &Value, operation: &str) -> Result<(), RpcError> {
        let line = format!("{payload}\n");
        let written = self.stdin.as_mut().map(|stdin| stdin.write_all(line.as_bytes()).and_then(|_| stdin.flush()));
        match written {
            Some(Ok(())) => Ok(()),
            _ => {
                self.stdin = None;
                Err(RpcError::Failed(format!("Codex app-server exited before {operation}")))
            }
        }
    }

    /// One request, and the reply carrying its id. Reads the raw pipe and
    /// splits lines here: the app-server can send notifications in the same
    /// write as a reply.
    fn request(&mut self, id: i64, method: &str, params: Value, timeout: Duration) -> Result<Map<String, Value>, RpcError> {
        self.send(&json!({"id": id, "method": method, "params": params}), method)?;
        let fd = self.child.stdout.as_ref().map(|s| s.as_raw_fd()).ok_or_else(|| RpcError::Failed(format!("Codex app-server exited before {method}")))?;
        let deadline = Instant::now() + timeout;
        loop {
            while let Some(at) = self.pending.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=at).collect();
                if let Ok(Value::Object(message)) = serde_json::from_slice::<Value>(&line[..line.len() - 1]) {
                    if message.get("id").and_then(Value::as_f64) == Some(id as f64) {
                        return Ok(message);
                    }
                }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(RpcError::Timeout(format!("Codex app-server did not answer {method}")));
            }
            let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            let wait = remaining.min(Duration::from_millis(250)).as_millis() as i32;
            let ready = unsafe { libc::poll(&mut poll, 1, wait.max(1)) };
            if ready <= 0 {
                if matches!(self.child.try_wait(), Ok(Some(_))) {
                    return Err(RpcError::Failed(format!("Codex app-server exited before {method}")));
                }
                continue;
            }
            let mut chunk = [0u8; 65536];
            let read = unsafe { libc::read(fd, chunk.as_mut_ptr().cast(), chunk.len()) };
            if read <= 0 {
                return Err(RpcError::Failed(format!("Codex app-server exited before {method}")));
            }
            self.pending.extend_from_slice(&chunk[..read as usize]);
        }
    }
}

fn limit_window(window: Option<&Value>) -> Option<Value> {
    let window = window?.as_object()?;
    let used = window.get("usedPercent").filter(|u| !u.is_null())?;
    let used = match used {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => s.trim().parse::<f64>().ok()?,
        Value::Bool(b) => f64::from(u8::from(*b)),
        _ => return None,
    };
    let mins = int(window.get("windowDurationMins"));
    let label = match mins {
        10080 => "Weekly (7-day)".to_string(),
        0 => "Limit".to_string(),
        m if m % 60 == 0 => format!("{}h window", m / 60),
        m => format!("{m}m window"),
    };
    let resets = if truthy(window.get("resetsAt")) { Utc.timestamp_opt(int(window.get("resetsAt")), 0).single().map(|at| iso(&at)).unwrap_or_default() } else { String::new() };
    Some(json!({"label": label, "percent": used / 100.0, "resetsAt": resets}))
}

/// OpenAI hands out free "full reset" credits that wipe the rate limits on
/// demand and lapse after a month. Worth knowing about before a limit bites.
fn reset_credits(result: &Value) -> Option<Value> {
    let granted = result.get("rateLimitResetCredits").and_then(|c| c.get("credits")).and_then(Value::as_array)?;
    let available: Vec<&Value> = granted.iter().filter(|c| c.get("status").and_then(Value::as_str) == Some("available")).collect();
    if available.is_empty() {
        return None;
    }
    let next = available.iter().map(|c| int(c.get("expiresAt"))).filter(|&t| t > 0).min();
    Some(json!({
        "available": available.len(),
        "nextExpiresAt": next.and_then(|t| Utc.timestamp_opt(t, 0).single()).map(|at| iso(&at)).unwrap_or_default(),
    }))
}

/// Keyring and auto stores keep credentials outside auth.json, so only the
/// file store can be known to be empty without asking Codex
fn has_codex_credentials(codex_home: &Path, access_token: bool) -> bool {
    if access_token {
        return true;
    }
    let config = match fs::read_to_string(codex_home.join("config.toml")) {
        Ok(raw) => match raw.parse::<toml::Table>() {
            Ok(table) => table,
            // A config this can't read may still name another store; let
            // Codex say
            Err(_) => return true,
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => toml::Table::new(),
        Err(_) => return true,
    };
    let store = match config.get("cli_auth_credentials_store") {
        Some(toml::Value::String(s)) if !s.is_empty() => s.clone(),
        Some(toml::Value::Boolean(true)) => "True".into(),
        Some(toml::Value::Integer(i)) if *i != 0 => i.to_string(),
        _ => "file".into(),
    };
    store != "file" || codex_home.join("auth.json").is_file()
}

/// Why the app-server RPC failed: a live server's stall, a dead one's own
/// stderr, or the login hint when it died saying nothing
fn rpc_help(child: &mut Child, stderr: Option<&mut File>, error: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline && matches!(child.try_wait(), Ok(None)) {
        std::thread::sleep(Duration::from_millis(20));
    }
    let message = error.trim();
    if matches!(child.try_wait(), Ok(None)) {
        // Still up: a stall or a payload this couldn't read. Not an auth
        // problem, and any stderr so far is its logging.
        let cut: String = message.chars().take(300).collect();
        return if cut.is_empty() { AUTH_HELP.into() } else { cut };
    }
    let mut detail = String::new();
    if let Some(file) = stderr {
        let mut bytes = Vec::new();
        if file.seek(SeekFrom::Start(0)).is_ok() && file.read_to_end(&mut bytes).is_ok() {
            detail = String::from_utf8_lossy(&bytes).into_owned();
        }
    }
    let lines: Vec<&str> = detail.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        // Exited cleanly saying nothing: the usual shape of "not logged in"
        return AUTH_HELP.into();
    }
    // The fatal error comes last, after whatever the CLI logged on the way up
    let joined = lines.join(" ");
    let chars: Vec<char> = joined.chars().collect();
    let tail: String = chars[chars.len().saturating_sub(275)..].iter().collect();
    format!("codex app-server exited: {tail}")
}

/// stderr goes to a file, not a pipe: an unread pipe can fill and deadlock a
/// chatty app-server. The file has no name, so nothing is left behind.
fn anonymous_file() -> Option<File> {
    let dir = std::env::temp_dir();
    let path = dir.join(format!(".neko-codex-{}-{}", std::process::id(), super::now_ms()));
    let file = fs::OpenOptions::new().read(true).write(true).create_new(true).open(&path).ok()?;
    let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    let _ = fs::remove_file(&path);
    Some(file)
}

fn fetch_codex_rpc(account_home: Option<PathBuf>) -> Value {
    let mut result = json!({"limits": [], "tierLabel": "", "usageStatusText": "", "authHelpText": AUTH_HELP});
    let Some(codex) = find_codex_binary() else {
        result["usageStatusText"] = json!("Codex unavailable");
        result["authHelpText"] = json!("codex not found in PATH");
        return result;
    };

    // No auth.json under the file store and no CODEX_ACCESS_TOKEN means
    // account/read can only fail, and starting the app-server is not free:
    // it syncs the plugin list, a git fetch per refresh. The home is the one
    // being probed, so a signed-out secondary account reads as signed out
    // even while ~/.codex holds a login.
    let probed_home = account_home.clone().unwrap_or_else(codex_home);
    let access_token = std::env::var("CODEX_ACCESS_TOKEN").is_ok_and(|t| !t.is_empty());
    if !has_codex_credentials(&probed_home, access_token) {
        result["usageStatusText"] = json!("Waiting for auth");
        return result;
    }

    let mut stderr = anonymous_file();
    let mut command = Command::new(&codex);
    command.args(["-s", "read-only", "-a", "on-request", "app-server"]).env("PATH", runtime_path()).stdin(Stdio::piped()).stdout(Stdio::piped());
    if let Some(home) = &account_home {
        command.env("CODEX_HOME", home);
    }
    match stderr.as_ref().and_then(|f| f.try_clone().ok()) {
        Some(file) => command.stderr(Stdio::from(file)),
        None => command.stderr(Stdio::null()),
    };
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            result["usageStatusText"] = json!("Codex unavailable");
            result["authHelpText"] = json!(error.to_string());
            return result;
        }
    };
    let stdin = child.stdin.take();
    let mut server = AppServer { child, stdin, pending: Vec::new() };

    let outcome = (|| -> Result<(), RpcError> {
        server.request(1, "initialize", json!({"clientInfo": {"name": "neko-agent-usage", "version": "1"}}), Duration::from_secs(8))?;
        server.send(&json!({"method": "initialized", "params": {}}), "initialized")?;
        let reply = server.request(2, "account/rateLimits/read", json!({}), Duration::from_secs(8))?;

        // A home nobody is signed in to answers with an error rather than
        // limits; say so the way the Claude collector does, so the panel
        // offers to sign that account in again
        if let Some(error) = reply.get("error").and_then(Value::as_object) {
            let message = text(error.get("message"));
            if message.to_lowercase().contains("auth") {
                result["usageStatusText"] = json!("Waiting for auth");
                result["authHelpText"] = json!(AUTH_HELP);
            } else {
                result["usageStatusText"] = json!("Codex limits unavailable");
                result["authHelpText"] = json!(message);
            }
            return Ok(());
        }
        let reply_result = reply.get("result").filter(|r| truthy(Some(r))).cloned().unwrap_or(json!({}));
        let limits = reply_result.get("rateLimits").filter(|l| truthy(Some(l))).cloned().unwrap_or(json!({}));
        result["authHelpText"] = json!("");
        let mut plan = limits.get("planType").filter(|p| truthy(Some(p))).cloned();

        // The limits name the plan themselves. account/read is only a
        // fallback for when they don't, and never a reason to lose them: an
        // app-server can leave it unanswered for good.
        if plan.is_none() {
            if let Ok(account_reply) = server.request(3, "account/read", json!({}), Duration::from_secs(2)) {
                let account = account_reply.get("result").and_then(|r| r.get("account")).cloned().unwrap_or(Value::Null);
                plan = [account.get("planType"), account.get("type")].into_iter().find(|v| truthy(*v)).flatten().cloned();
            }
        }
        result["tierLabel"] = json!(plan.map(|p| text(Some(&p))).unwrap_or_default());

        let windows: Vec<Value> = [limits.get("primary"), limits.get("secondary")].into_iter().filter_map(limit_window).collect();
        result["limits"] = json!(windows);
        if let Some(credits) = reset_credits(&reply_result) {
            result["resetCredits"] = credits;
        }
        Ok(())
    })();

    if let Err(error) = outcome {
        result["usageStatusText"] = json!("Codex limits unavailable");
        result["authHelpText"] = json!(rpc_help(&mut server.child, stderr.as_mut(), error.message()));
    }
    server.stdin = None;
    unsafe { libc::kill(server.child.id() as i32, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline && matches!(server.child.try_wait(), Ok(None)) {
        std::thread::sleep(Duration::from_millis(10));
    }
    if matches!(server.child.try_wait(), Ok(None)) {
        let _ = server.child.kill();
    }
    let _ = server.child.wait();
    result
}

/// Each account's app-server runs in that account's home, so it answers for
/// that login and refreshes that login's tokens there
fn account_limits(account: &Map<String, Value>) -> Value {
    // The primary is ~/.codex by definition, not whatever CODEX_HOME this run
    // inherited, which would report another account's limits as Main's
    let account_home = if truthy(account.get("home")) { PathBuf::from(text(account.get("home"))) } else { home().join(".codex") };
    let rpc = fetch_codex_rpc(Some(account_home));
    let id = text(account.get("id"));
    let label = text(account.get("label"));
    let tier = text(rpc.get("tierLabel"));
    json!({
        "id": account["id"],
        "label": if label.is_empty() { id } else { label },
        "email": text(account.get("email")),
        "plan": if tier.is_empty() { text(account.get("plan")) } else { tier },
        "active": account["active"],
        "primary": truthy(account.get("primary")),
        "limits": rpc["limits"],
        "stale": !truthy(rpc.get("limits")),
        "usageStatusText": rpc["usageStatusText"],
        "authHelpText": rpc["authHelpText"],
        "resetCredits": rpc.get("resetCredits").cloned().unwrap_or(Value::Null),
    })
}

