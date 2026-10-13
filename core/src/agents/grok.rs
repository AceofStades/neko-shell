//! Grok usage as one display-ready JSON record.
//!
//! The plan comes from the settings Grok caches from xAI, and the limit from
//! the credits endpoint the Grok CLI itself reads for its /usage view, asked
//! with each account's own sign-in. Sessions come from the summary Grok keeps
//! beside each session, and tokens and prompts from its usage.json, the
//! ledger `grok usage` prints: one entry per finished turn, with when it
//! ended and its tokens by model. The agents panel only ever reads the JSON
//! this prints.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{Local, Utc};
use serde_json::{json, Map, Value};

use super::{cache_root, day_string, home, int, iso, now_ms, now_secs, parse_utc, read_json, recent_dates, safe_key, text, today, write_json};

const AUTH_HELP: &str = "Start Grok, or run `grok login`, to sign in.";
const CREDITS_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
// Grok's own CLI watches its subscription once a minute; a panel opened and
// shut repeatedly reuses an answer for about that long.
const PROBE_REUSE_SECONDS: f64 = 60.0;
// Grok's docs give a saved sign-in 30 days; a refresh token older than that
// can't renew the access token, so it no longer counts as signed in.
const REFRESH_LIFETIME_SECONDS: f64 = 30.0 * 24.0 * 3600.0;
// A limits-only refresh needs fresh limits, not a fresh history scan.
const LIMITS_ONLY_SCAN_REUSE_SECONDS: f64 = 900.0;

pub fn run(args: &[String]) -> Result<(), String> {
    let flags = super::flags(args, &[])?;

    let registered = super::registered_accounts("grok");
    let accounts: Vec<Value> = registered.iter().map(|account| account_limits(account, flags.force)).collect();
    let current = accounts.iter().find(|a| a["active"] == json!(true));
    let (tier, limits) = match current {
        Some(current) => (text(current.get("plan")), Limits {
            limits: current["limits"].clone(),
            status: text(current.get("usageStatusText")),
            help: text(current.get("authHelpText")),
            live: current["stale"] != json!(true),
            fetched_at: current["fetchedAt"].clone(),
        }),
        None => {
            let home = default_home();
            (plan(&home), collect_limits(&home, &cache_key(&home, "main"), flags.force))
        }
    };

    // Nobody signed in to Grok here: an empty record, which the panel skips.
    // With accounts registered, the primary is ~/.grok by definition.
    let stats_home = if accounts.is_empty() { default_home() } else { home().join(".grok") };
    let signed_in = !accounts.is_empty() || !login(&stats_home).is_empty();
    let mut record = json!({
        "schemaVersion": 1,
        "id": "grok",
        "name": "Grok",
        "updatedAt": super::iso_now_utc(),
        "ready": signed_in,
        "tierLabel": tier,
        "usageStatusText": limits.status,
        "authHelpText": limits.help,
        "limits": limits.limits,
        "limitsStale": !limits.live,
        "limitsFetchedAt": limits.fetched_at,
    });
    let reuse = if flags.limits_only && !flags.force { LIMITS_ONLY_SCAN_REUSE_SECONDS } else { 0.0 };
    let map = record.as_object_mut().unwrap();
    if let Value::Object(stats) = cached_local_stats(&stats_home, reuse) {
        map.extend(stats);
    }
    if !accounts.is_empty() {
        map.insert("accountSwitch".into(), registered[0]["switch"].clone());
        map.insert("accounts".into(), Value::Array(accounts));
    }
    super::print_compact(&record);
    Ok(())
}

/// The home Grok uses when nothing selects an account: GROK_HOME when set, as
/// the CLI itself reads it, else ~/.grok
fn default_home() -> PathBuf {
    super::env_or("GROK_HOME", home().join(".grok"))
}

/// Every session under <home>/sessions/<folder>/<session>/: its summary says
/// when it was last active and how many prompts it had, and its usage.json
/// lists each finished turn with its tokens by model. Added accounts link
/// their sessions to the primary's, so this covers all of them. Grok counts
/// cached input inside inputTokens; the record keeps the two apart, as the
/// other collectors do.
fn local_stats(home: &Path) -> Value {
    let today = day_string(today());
    let week = recent_dates();
    let (mut prompts, mut sessions, mut today_sessions, mut today_prompts, mut today_tokens) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut days = BTreeSet::new();
    let mut by_day: BTreeMap<String, i64> = week.iter().map(|d| (d.clone(), 0)).collect();
    let mut today_by_model = Map::new();
    let mut models = Map::new();

    for session in session_dirs(&home.join("sessions")) {
        if let Some(summary) = read_json(&session.join("summary.json")).filter(Value::is_object) {
            if let Some(active) = parse_utc(&text(summary.get("last_active_at"))) {
                let day = day_string(active.with_timezone(&Local).date_naive());
                sessions += 1;
                prompts += int(summary.get("num_messages"));
                if day == today {
                    today_sessions += 1;
                }
                days.insert(day);
            }
        }

        let usage = read_json(&session.join("usage.json"));
        let turns = usage.as_ref().and_then(|u| u.get("turns")).and_then(Value::as_array).cloned().unwrap_or_default();
        for turn in &turns {
            let Some(ended) = turn.as_object().and_then(|t| parse_utc(&text(t.get("endedAt")))) else { continue };
            let day = day_string(ended.with_timezone(&Local).date_naive());
            days.insert(day.clone());
            if day == today {
                today_prompts += 1;
            }
            for (model, bucket) in turn.get("modelUsage").and_then(Value::as_object).into_iter().flatten() {
                let Some(bucket) = bucket.as_object() else { continue };
                // Grok's totalTokens leaves cache writes out; counting them
                // here keeps the day's total equal to the sum of its model's
                // buckets.
                let cached = int(bucket.get("cachedReadTokens"));
                let uncached = (int(bucket.get("inputTokens")) - cached).max(0);
                let output = int(bucket.get("outputTokens"));
                let created = int(bucket.get("cacheCreationTokens"));
                let tokens = uncached + cached + output + created;
                let totals = models.entry(model.clone()).or_insert_with(|| super::Bucket::default().json());
                for (field, add) in [("inputTokens", uncached), ("outputTokens", output), ("cacheReadInputTokens", cached), ("cacheCreationInputTokens", created)] {
                    totals[field] = json!(totals[field].as_i64().unwrap_or(0) + add);
                }
                if let Some(count) = by_day.get_mut(&day) {
                    *count += tokens;
                }
                if day == today {
                    today_tokens += tokens;
                    let sum = today_by_model.get(model).and_then(Value::as_i64).unwrap_or(0) + tokens;
                    today_by_model.insert(model.clone(), json!(sum));
                }
            }
        }
    }

    json!({
        "hasLocalStats": sessions > 0,
        "todayPrompts": today_prompts,
        "todaySessions": today_sessions,
        "todayTotalTokens": today_tokens,
        "todayTokensByModel": today_by_model,
        "recentDays": week.iter().map(|d| json!({"date": d, "messageCount": by_day[d]})).collect::<Vec<_>>(),
        "totalPrompts": prompts,
        "totalSessions": sessions,
        "activeDays": days.len(),
        "activeDates": days.into_iter().collect::<Vec<_>>(),
        "modelUsage": models,
    })
}

/// The visible directories two levels down, as the glob sessions/*/*/ finds
fn session_dirs(root: &Path) -> Vec<PathBuf> {
    let visible_dirs = |dir: &Path| -> Vec<PathBuf> {
        fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect()
    };
    visible_dirs(root).iter().flat_map(|folder| visible_dirs(folder)).collect()
}

/// A scan from before midnight would count yesterday's sessions as today's
fn cached_local_stats(home: &Path, max_age: f64) -> Value {
    let cache = cache_root().join("grok-stats.json");
    let cached = read_json(&cache).unwrap_or(Value::Null);
    let today = day_string(today());
    let home_text = home.to_string_lossy();
    let at = cached.get("at").and_then(Value::as_f64).unwrap_or(0.0);
    if cached.get("home").and_then(Value::as_str) == Some(&home_text) && cached.get("day").and_then(Value::as_str) == Some(&today) && now_secs() - at < max_age {
        if let Some(stats) = cached.get("stats") {
            return stats.clone();
        }
    }
    let stats = local_stats(home);
    let _ = write_json(&cache, &json!({"home": home_text, "day": today, "at": now_secs(), "stats": stats}), 0o600, false);
    stats
}

/// One login per issuer in auth.json; the first is the CLI's own
fn login(home: &Path) -> Map<String, Value> {
    read_json(&home.join("auth.json"))
        .and_then(|auth| auth.as_object().and_then(|a| a.values().find_map(|v| v.as_object().cloned())))
        .unwrap_or_default()
}

fn plan(home: &Path) -> String {
    let cached = read_json(&home.join("settings_cache.json")).unwrap_or(Value::Null);
    let payload = text(cached.get("payload"));
    let payload = if payload.is_empty() { "{}".to_string() } else { payload };
    let Ok(parsed) = serde_json::from_str::<Value>(&payload) else { return String::new() };
    text(parsed.get("settings").and_then(|s| s.get("subscription_tier_display")))
}

/// The credits answer as one limit window: how much of this period's
/// included usage is gone, and when the period ends. The answer is protobuf
/// JSON, which leaves out a field holding zero, so a period with nothing used
/// yet has no percentage at all.
fn credits_limit(data: &Value) -> Option<Value> {
    let config = data.get("config")?.as_object()?;
    let period = config.get("currentPeriod")?.as_object()?;
    let percent = match config.get("creditUsagePercent") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) if !s.is_empty() => s.trim().parse::<f64>().ok()?,
        _ => 0.0,
    };
    let kind = match period.get("type") {
        Some(Value::String(s)) => s.clone(),
        other => other.map(Value::to_string).unwrap_or_default(),
    };
    let end = parse_utc(period.get("end")?.as_str()?)?;
    Some(json!({
        "label": if kind.contains("WEEK") { "Weekly" } else { "Monthly" },
        "percent": (percent / 100.0).clamp(0.0, 1.0),
        "resetsAt": iso(&end),
    }))
}

/// A window whose reset has passed starts over empty. A weekly one's next
/// reset is a whole number of weeks later; a monthly one's isn't known.
fn rolled_forward(limits: &Value) -> Value {
    let now = Utc::now();
    let week = chrono::Duration::weeks(1);
    let rolled = limits.as_array().into_iter().flatten().map(|limit| {
        let Some(resets) = parse_utc(&text(limit.get("resetsAt"))) else { return limit.clone() };
        if resets > now {
            return limit.clone();
        }
        let mut limit = limit.clone();
        limit["percent"] = json!(0.0);
        limit["resetsAt"] = json!("");
        if limit.get("label").and_then(Value::as_str) == Some("Weekly") {
            let elapsed = now.signed_duration_since(resets);
            let weeks = (elapsed.num_microseconds().unwrap_or(i64::MAX) / week.num_microseconds().unwrap()) as i32 + 1;
            limit["resetsAt"] = json!(iso(&(resets + week * weeks)));
        }
        limit
    });
    Value::Array(rolled.collect())
}

struct Limits {
    limits: Value,
    status: String,
    help: String,
    live: bool,
    fetched_at: Value,
}

fn non_empty_list(value: Option<&Value>) -> Option<Value> {
    value.filter(|v| v.as_array().is_some_and(|a| !a.is_empty())).cloned()
}

fn collect_limits(home: &Path, key: &str, force: bool) -> Limits {
    let mut result = Limits { limits: json!([]), status: String::new(), help: AUTH_HELP.into(), live: false, fetched_at: json!(0) };
    let entry = login(home);
    let token = text(entry.get("key"));
    if token.is_empty() {
        result.status = "Waiting for auth".into();
        return result;
    }

    let cache = cache_root().join(format!("grok-limits-{key}.json"));
    let cached = read_json(&cache).unwrap_or(Value::Null);
    let cached_limits = non_empty_list(cached.get("limits"));
    let fetched_at = cached.get("fetchedAtMs").and_then(Value::as_f64).unwrap_or(0.0);
    result.fetched_at = json!(fetched_at);

    if let Some(expires) = parse_utc(&text(entry.get("expires_at"))) {
        let expires = expires.timestamp() as f64 + f64::from(expires.timestamp_subsec_micros()) / 1e6;
        if expires <= now_secs() {
            result.limits = cached_limits.unwrap_or(json!([]));
            // The access token lives six hours and Grok mints a new one from
            // its refresh token whenever it starts, so a lapsed one is
            // routine, not a sign-out. And while Grok hasn't run, nothing
            // here has spent its allowance, so the last numbers still stand,
            // rolled past any reset.
            if !text(entry.get("refresh_token")).is_empty() && now_secs() - expires < REFRESH_LIFETIME_SECONDS {
                result.limits = rolled_forward(&result.limits);
                result.live = true;
                if result.limits.as_array().is_none_or(Vec::is_empty) {
                    result.status = "Limits paused".into();
                    result.help = "Start Grok to see its limits; signing in again is not needed.".into();
                }
            } else {
                result.status = "Sign-in expired".into();
                result.help = "Grok's saved sign-in expired. Start Grok to refresh it.".into();
            }
            return result;
        }
    }

    if let Some(limits) = &cached_limits {
        if !force && now_secs() - fetched_at / 1000.0 < PROBE_REUSE_SECONDS {
            result.limits = limits.clone();
            result.live = true;
            result.help.clear();
            return result;
        }
    }

    let response = ureq::get(CREDITS_URL)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", "application/json")
        .timeout(Duration::from_secs(8))
        .call();
    let limit = match response {
        Ok(response) => response.into_string().ok().and_then(|body| serde_json::from_str::<Value>(&body).ok()).and_then(|data| credits_limit(&data)),
        Err(ureq::Error::Status(401 | 403, _)) => {
            result.status = "Waiting for auth".into();
            None
        }
        Err(_) => None,
    };

    match limit {
        Some(limit) => {
            result.limits = json!([limit]);
            result.live = true;
            result.fetched_at = json!(now_ms());
            result.help.clear();
            let _ = write_json(&cache, &json!({"fetchedAtMs": result.fetched_at, "limits": result.limits}), 0o600, false);
        }
        None => {
            result.limits = cached_limits.unwrap_or(json!([]));
            if result.status.is_empty() && result.limits.as_array().is_none_or(Vec::is_empty) {
                result.status = "Grok limits unavailable".into();
            }
        }
    }
    result
}

fn home_of(account: &Map<String, Value>) -> PathBuf {
    let home = text(account.get("home"));
    if home.is_empty() { super::home().join(".grok") } else { PathBuf::from(home) }
}

/// Keyed by who the home is signed in as, so a home signed in to someone
/// else never shows the last one's numbers
fn cache_key(home: &Path, fallback: &str) -> String {
    let key = safe_key(&text(login(home).get("user_id")));
    if key.is_empty() { fallback.to_string() } else { key }
}

fn account_limits(account: &Map<String, Value>, force: bool) -> Value {
    let home = home_of(account);
    let id = text(account.get("id"));
    let limits = collect_limits(&home, &cache_key(&home, &id), force);
    let label = text(account.get("label"));
    let plan = plan(&home);
    json!({
        "id": account["id"],
        "label": if label.is_empty() { id } else { label },
        "email": text(account.get("email")),
        "plan": if plan.is_empty() { text(account.get("plan")) } else { plan },
        "active": account["active"],
        "primary": super::truthy(account.get("primary")),
        "limits": limits.limits,
        "stale": !limits.live,
        "fetchedAt": limits.fetched_at,
        "usageStatusText": limits.status,
        "authHelpText": limits.help,
    })
}
