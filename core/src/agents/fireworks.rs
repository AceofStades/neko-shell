//! Fireworks serverless usage as one display-ready JSON record.
//!
//! Token stats come from the Fireworks billing API grouped by day and model
//! for the last 30 days. Fireworks does not expose its prepaid ledger, so the
//! record carries an estimated balance instead of rate limits: the credits
//! configured in ~/.config/neko/agents/fireworks.json minus rated account
//! costs since the funding date. The agents panel only ever reads the JSON
//! this prints.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
use serde_json::{json, Map, Value};

use super::{day_string, home, iso, parse_iso, parse_utc, read_json, recent_dates, text, Parsed};

const AUTH_HELP: &str = "Set FIREWORKS_API_KEY, run `firectl set-api-key`, or sign in to Fireworks in pi or opencode.";
const API_BASE_URL: &str = "https://api.fireworks.ai";

pub fn run(args: &[String]) -> Result<(), String> {
    // Stats and balance come from the same few API calls, so there is no
    // cache to force past and no faster limits-only path. The flags exist so
    // every collector accepts the same invocation.
    let flags = super::flags(args, &["--auth-path", "--api-base-url"])?;
    let option = |name: &str, env: &str, default: &str| {
        flags.rest.iter().rev().find(|(flag, _)| flag == name).map(|(_, value)| value.clone()).unwrap_or_else(|| {
            std::env::var(env).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.to_string())
        })
    };
    let auth_path = super::expand_user(&option("--auth-path", "FIREWORKS_AUTH_PATH", "~/.fireworks/auth.ini"));
    let base_url = option("--api-base-url", "FIREWORKS_API_BASE_URL", API_BASE_URL);

    let record = match scan(&base_url, &auth_path) {
        Ok(record) => record,
        Err(Failure::Fireworks(message)) => base_record(&[("usageStatusText", json!("Fireworks unavailable")), ("authHelpText", json!(message))]),
        Err(Failure::Other(kind)) => {
            eprintln!("neko-agent-usage-fireworks: {kind}");
            base_record(&[("usageStatusText", json!("Fireworks unavailable")), ("authHelpText", json!("Fireworks usage scan failed"))])
        }
    };
    super::print_compact(&record);
    Ok(())
}

enum Failure {
    /// A failure worth telling the user about, word for word
    Fireworks(String),
    /// Anything else: the record only says the scan failed
    Other(&'static str),
}

fn fail<T>(message: &str) -> Result<T, Failure> {
    Err(Failure::Fireworks(message.to_string()))
}

// ------------------------------------------------------------------ money

/// An amount of money in billionths, exact as Decimal kept it
#[derive(Clone, Copy, PartialEq, PartialOrd)]
struct Money(i128);

const NANO: i128 = 1_000_000_000;

impl Money {
    const ZERO: Money = Money(0);

    /// A decimal number written out, as Decimal(str(value)) reads it
    fn parse(raw: &str) -> Result<Money, Decimal> {
        let s = raw.trim().replace('_', "");
        let lower = s.to_ascii_lowercase();
        let unsigned = lower.trim_start_matches(['+', '-']);
        if ["inf", "infinity", "nan", "snan"].contains(&unsigned) {
            return Err(Decimal::NotFinite);
        }
        let (mantissa, exponent) = match lower.split_once('e') {
            Some((m, e)) => (m.to_string(), e.parse::<i32>().map_err(|_| Decimal::Invalid)?),
            None => (lower.clone(), 0),
        };
        let negative = mantissa.starts_with('-');
        let digits = mantissa.trim_start_matches(['+', '-']);
        let (whole, fraction) = digits.split_once('.').unwrap_or((digits, ""));
        if (whole.is_empty() && fraction.is_empty()) || !whole.chars().chain(fraction.chars()).all(|c| c.is_ascii_digit()) {
            return Err(Decimal::Invalid);
        }
        // The digits as one integer, and where the decimal point goes
        let all = format!("{whole}{fraction}");
        let mut scale = exponent - fraction.len() as i32 + 9;
        let mut value: i128 = 0;
        for c in all.chars() {
            value = value.checked_mul(10).and_then(|v| v.checked_add(i128::from(c as u8 - b'0'))).ok_or(Decimal::Invalid)?;
        }
        while scale > 0 {
            value = value.checked_mul(10).ok_or(Decimal::Invalid)?;
            scale -= 1;
        }
        while scale < 0 {
            value /= 10;
            scale += 1;
        }
        Ok(Money(if negative { -value } else { value }))
    }

    /// A Money object of the API, {units, nanos}; anything else is nothing
    fn from_value(value: Option<&Value>) -> Money {
        let Some(map) = value.and_then(Value::as_object) else { return Money::ZERO };
        let part = |key: &str| -> Option<Money> {
            match map.get(key) {
                None | Some(Value::Null) => Some(Money::ZERO),
                Some(v) if !super::truthy(Some(v)) => Some(Money::ZERO),
                Some(Value::String(s)) => Money::parse(s).ok(),
                Some(Value::Number(n)) => Money::parse(&n.to_string()).ok(),
                Some(_) => None,
            }
        };
        match (part("units"), part("nanos")) {
            // nanos are billionths already, so their Money is a billion too big
            (Some(units), Some(nanos)) => Money(units.0 + nanos.0 / NANO),
            _ => Money::ZERO,
        }
    }

    fn float(self) -> f64 {
        let sign = if self.0 < 0 { "-" } else { "" };
        let abs = self.0.unsigned_abs();
        format!("{sign}{}.{:09}", abs / NANO as u128, abs % NANO as u128).parse().unwrap_or(0.0)
    }
}

enum Decimal {
    Invalid,
    NotFinite,
}

// ------------------------------------------------------------------ stats

fn base_record(overrides: &[(&str, Value)]) -> Value {
    let mut record = json!({
        "schemaVersion": 1,
        "id": "fireworks",
        "name": "Fireworks",
        "updatedAt": super::iso_now_utc(),
        "ready": false,
        "hasLocalStats": false,
        // Billing-API numbers are account-global, not machine-local: every
        // synced device reports the same truth, so aggregation must not sum
        // them.
        "scope": "account",
        // The billing API reports tokens, never prompt or session counts; the
        // panel keeps those numbers out of today's tooltip when this is false.
        "hasPromptStats": false,
        "tierLabel": "Prepaid",
        "usageStatusText": "",
        "authHelpText": "",
        "limits": [],
        "todayPrompts": 0,
        "todaySessions": 0,
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": [],
        "totalPrompts": 0,
        "totalSessions": 0,
        "activeDays": 0,
        "activeDates": [],
        "modelUsage": {},
    });
    for (key, value) in overrides {
        record[*key] = value.clone();
    }
    record
}

fn count(value: Option<&Value>) -> i64 {
    super::number(value).max(0)
}

fn model_id(row: &Map<String, Value>) -> String {
    let group = row.get("group").and_then(Value::as_object);
    let raw = [group.and_then(|g| g.get("model_name")), row.get("modelName")]
        .into_iter()
        .find(|v| super::truthy(*v))
        .map(|v| text(v))
        .unwrap_or_else(|| "unknown".into());
    let name = raw.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
    let name = if name.is_empty() { "unknown".to_string() } else { name };
    // A p between digits is a decimal point: llama-v3p1 is llama-v3.1
    let chars: Vec<char> = name.chars().collect();
    chars
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            let between_digits = i > 0 && i + 1 < chars.len() && chars[i - 1].is_ascii_digit() && chars[i + 1].is_ascii_digit();
            if c == 'p' && between_digits { '.' } else { c }
        })
        .collect()
}

/// The query asks for day buckets in the local timezone, but the API reports
/// each bucket's boundary in UTC: local Aug 7 starts at Aug 6 22:00Z east of
/// Greenwich. Convert back to local time to recover the day the bucket names;
/// taking the raw date prefix would file every day under its predecessor.
fn row_date(row: &Map<String, Value>) -> String {
    let raw = text(row.get("startTime"));
    if raw.is_empty() {
        return String::new();
    }
    match parse_iso(&raw) {
        Some(Parsed::Aware(at)) => day_string(at.with_timezone(&Local).date_naive()),
        Some(Parsed::Naive(at)) => day_string(Utc.from_utc_datetime(&at).with_timezone(&Local).date_naive()),
        None if raw.chars().count() >= 10 => raw.chars().take(10).collect(),
        None => String::new(),
    }
}

fn summarize_usage(rows: &[Value]) -> Vec<(&'static str, Value)> {
    let today = day_string(super::today());
    let week = recent_dates();
    let mut recent: Map<String, Value> = week.iter().map(|d| (d.clone(), json!(0))).collect();
    let mut today_by_model = Map::new();
    let mut model_usage = Map::new();
    let mut active_dates = BTreeSet::new();

    for row in rows.iter().filter_map(Value::as_object) {
        let day = row_date(row);
        let model = model_id(row);
        let prompt = count(row.get("promptTokens"));
        let cached = prompt.min(count(row.get("cachedPromptTokens")));
        let uncached = if row.contains_key("uncachedPromptTokens") { count(row.get("uncachedPromptTokens")) } else { (prompt - cached).max(0) };
        let output = count(row.get("completionTokens"));
        let total = uncached + cached + output;
        if total <= 0 {
            continue;
        }

        let bucket = model_usage.entry(model.clone()).or_insert_with(|| super::Bucket::default().json());
        for (field, add) in [("inputTokens", uncached), ("outputTokens", output), ("cacheReadInputTokens", cached)] {
            bucket[field] = json!(bucket[field].as_i64().unwrap_or(0) + add);
        }

        if !day.is_empty() {
            active_dates.insert(day.clone());
        }
        if let Some(sum) = recent.get_mut(&day) {
            *sum = json!(sum.as_i64().unwrap_or(0) + total);
        }
        if day == today {
            let sum = today_by_model.get(&model).and_then(Value::as_i64).unwrap_or(0) + total;
            today_by_model.insert(model, json!(sum));
        }
    }

    let today_total: i64 = today_by_model.values().filter_map(Value::as_i64).sum();
    vec![
        ("todayTotalTokens", json!(today_total)),
        ("todayTokensByModel", Value::Object(today_by_model)),
        ("recentDays", week.iter().map(|d| json!({"date": d, "messageCount": recent[d]})).collect()),
        ("activeDays", json!(active_dates.len())),
        ("activeDates", json!(active_dates)),
        ("modelUsage", Value::Object(model_usage)),
    ]
}

// ------------------------------------------------------------ credentials

/// firectl's auth.ini: the first api_key and account_id, from the keys before
/// any section or in [DEFAULT] first, then each section in order
fn read_auth_file(path: &Path) -> (String, String) {
    let Ok(content) = fs::read_to_string(path) else { return Default::default() };
    let mut sections: Vec<(String, Vec<(String, String)>)> = vec![("DEFAULT".into(), vec![])];
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }
        if let Some(name) = trimmed.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            sections.push((name.to_string(), vec![]));
            continue;
        }
        let split = trimmed.find(['=', ':']);
        let Some(at) = split else { continue };
        let key = trimmed[..at].trim().to_ascii_lowercase();
        let value = trimmed[at + 1..].trim().to_string();
        let index = if sections.last().is_some_and(|(name, _)| name == "DEFAULT") { 0 } else { sections.len() - 1 };
        sections[index].1.push((key, value));
    }
    // A section sees [DEFAULT]'s keys too, but its own come first
    let defaults = sections[0].1.clone();
    let lookup = |own: &[(String, String)], names: [&str; 2]| -> String {
        for name in names {
            if let Some((_, v)) = own.iter().rev().find(|(k, _)| k == name).or_else(|| defaults.iter().rev().find(|(k, _)| k == name)) {
                return v.trim().to_string();
            }
        }
        String::new()
    };
    let (mut api_key, mut account_id) = (String::new(), String::new());
    for (_, values) in &sections {
        if api_key.is_empty() {
            api_key = lookup(values, ["api_key", "api-key"]);
        }
        if account_id.is_empty() {
            account_id = lookup(values, ["account_id", "account-id"]);
        }
    }
    (api_key, account_id)
}

/// pi credential keys are literals, $ENV_VAR/${ENV_VAR} references, or
/// !command shell lookups. The collector resolves the first two; command
/// lookups stay pi-only and are skipped rather than sent to the API verbatim.
fn resolve_pi_key(raw: Option<&Value>) -> String {
    let key = text(raw).trim().to_string();
    if key.is_empty() || key.starts_with('!') {
        return String::new();
    }
    // Escapes survive interpolation as sentinels, then restore
    let key = key.replace("$$", "\x00").replace("$!", "\x01");
    let chars: Vec<char> = key.chars().collect();
    let is_start = |c: char| c.is_ascii_alphabetic() || c == '_';
    let is_name = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '$' {
            let braced = chars.get(i + 1) == Some(&'{');
            let start = if braced { i + 2 } else { i + 1 };
            if chars.get(start).is_some_and(|&c| is_start(c)) {
                let mut end = start + 1;
                while end < chars.len() && is_name(chars[end]) {
                    end += 1;
                }
                if !braced || chars.get(end) == Some(&'}') {
                    let name: String = chars[start..end].iter().collect();
                    match std::env::var(&name) {
                        Ok(value) if !value.is_empty() => out.push_str(&value),
                        _ => return String::new(),
                    }
                    i = if braced { end + 1 } else { end };
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out.replace('\x00', "$").replace('\x01', "!")
}

fn read_pi_key(path: &Path) -> String {
    let Some(entry) = read_json(path).and_then(|p| p.get("fireworks").cloned()).filter(Value::is_object) else { return String::new() };
    match entry.get("type") {
        None | Some(Value::Null) => {}
        Some(Value::String(kind)) if kind == "api_key" => {}
        _ => return String::new(),
    }
    resolve_pi_key(entry.get("key"))
}

fn read_opencode_key(path: &Path) -> String {
    read_json(path)
        .and_then(|p| p.get("fireworks-ai").cloned())
        .filter(Value::is_object)
        .map(|entry| text(entry.get("key")).trim().to_string())
        .unwrap_or_default()
}

fn config_path() -> PathBuf {
    super::xdg("XDG_CONFIG_HOME", ".config").join("neko/agents/fireworks.json")
}

fn env_text(name: &str) -> String {
    std::env::var(name).unwrap_or_default().trim().to_string()
}

fn credentials(auth_path: &Path, config: &Value) -> (String, String) {
    let (file_key, file_account) = read_auth_file(auth_path);
    // Agent logins are the fallback ladder below an explicit key or a firectl
    // login: pi first as neko's default agent, opencode as the last resort.
    let pi_auth = super::env_or("PI_CODING_AGENT_DIR", home().join(".pi/agent")).join("auth.json");
    let opencode_auth = super::xdg("XDG_DATA_HOME", ".local/share").join("opencode/auth.json");
    let first = |candidates: Vec<Box<dyn Fn() -> String + '_>>| candidates.iter().map(|f| f()).find(|v| !v.is_empty()).unwrap_or_default();
    let api_key = first(vec![
        Box::new(|| env_text("FIREWORKS_API_KEY")),
        Box::new(|| file_key.clone()),
        Box::new(|| read_pi_key(&pi_auth)),
        Box::new(|| read_opencode_key(&opencode_auth)),
    ]);
    let account_id = first(vec![
        Box::new(|| env_text("FIREWORKS_ACCOUNT_ID")),
        Box::new(|| text(config.get("accountId")).trim().to_string()),
        Box::new(|| file_account.clone()),
    ]);
    (api_key, account_id)
}

fn normalize_account_id(value: &str) -> String {
    let value = value.trim();
    value.strip_prefix("accounts/").unwrap_or(value).trim_matches('/').to_string()
}

fn timezone_name() -> String {
    let configured = env_text("TZ");
    if !configured.is_empty() {
        return configured;
    }
    if let Ok(target) = fs::canonicalize("/etc/localtime") {
        if let Some((_, name)) = target.to_string_lossy().split_once("/zoneinfo/") {
            return name.to_string();
        }
    }
    "UTC".into()
}

fn utc_z(at: DateTime<Utc>) -> String {
    iso(&at).replace("+00:00", "Z")
}

/// The API buckets by the requested timezone, so the window must run between
/// local midnights, expressed in UTC, since a bare date with a Z suffix
/// shifts the window by the UTC offset and clips today's tail west of
/// Greenwich.
fn local_midnight_utc(day: NaiveDate) -> String {
    let midnight = day.and_hms_opt(0, 0, 0).unwrap();
    let local = Local.from_local_datetime(&midnight).earliest().unwrap_or_else(|| Local.from_utc_datetime(&midnight));
    utc_z(local.with_timezone(&Utc))
}

fn iso_timestamp(value: &str) -> Result<String, Failure> {
    let raw = value.trim();
    if raw.is_empty() {
        return Ok(String::new());
    }
    let parsed = if raw.chars().count() == 10 {
        NaiveDate::parse_from_str(raw, "%Y-%m-%d").ok().map(|day| Utc.from_utc_datetime(&day.and_hms_opt(0, 0, 0).unwrap()))
    } else {
        parse_utc(raw).map(|at| at.with_timezone(&Utc))
    };
    match parsed {
        Some(at) => Ok(utc_z(at)),
        None => fail("Fireworks fundedAt must be an ISO date such as 2026-07-01"),
    }
}

// ---------------------------------------------------------------- the API

/// urlencode's quote_plus
fn quote(raw: &str, safe: &str) -> String {
    let mut out = String::new();
    for byte in raw.bytes() {
        let c = byte as char;
        if c.is_ascii_alphanumeric() || "_.-~".contains(c) || safe.contains(c) {
            out.push(c);
        } else if c == ' ' && safe.is_empty() {
            out.push('+');
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

struct Client {
    api_key: String,
    base_url: String,
}

impl Client {
    fn request(&self, path: &str, query: &[(&str, String)], body: Option<&Value>) -> Result<Map<String, Value>, Failure> {
        let mut url = format!("{}{path}", self.base_url);
        if !query.is_empty() {
            let pairs: Vec<String> = query.iter().map(|(k, v)| format!("{}={}", quote(k, ""), quote(v, ""))).collect();
            url = format!("{url}?{}", pairs.join("&"));
        }
        let request = match body {
            Some(_) => ureq::post(&url),
            None => ureq::get(&url),
        }
        .set("Authorization", &format!("Bearer {}", self.api_key))
        .set("Accept", "application/json")
        .set("Content-Type", "application/json")
        .timeout(Duration::from_secs(15));
        let response = match body {
            Some(body) => request.send_string(&body.to_string()),
            None => request.call(),
        };
        match response {
            Ok(response) => {
                let body = response.into_string().map_err(|_| Failure::Fireworks("Fireworks returned an invalid billing response".into()))?;
                match serde_json::from_str::<Value>(&body) {
                    Ok(Value::Object(map)) => Ok(map),
                    Ok(_) => Ok(Map::new()),
                    Err(_) => fail("Fireworks returned an invalid billing response"),
                }
            }
            Err(ureq::Error::Status(code, _)) => fail(&match code {
                401 => "Fireworks rejected the API key".to_string(),
                403 => "The Fireworks API key cannot read billing data".to_string(),
                404 => "Fireworks account not found".to_string(),
                _ => format!("Fireworks API returned HTTP {code}"),
            }),
            Err(_) => fail("Could not reach the Fireworks API"),
        }
    }

    fn account_path(account_id: &str) -> String {
        format!("/v1/accounts/{}", quote(&normalize_account_id(account_id), "\0"))
    }

    fn discover_account(&self) -> Result<(String, Map<String, Value>), Failure> {
        let payload = self.request("/v1/accounts", &[("pageSize", "100".into())], None)?;
        let accounts: Vec<Map<String, Value>> = match payload.get("accounts") {
            None => vec![],
            Some(Value::Array(items)) => items.iter().filter_map(|i| i.as_object().cloned()).collect(),
            Some(_) => return Err(Failure::Other("TypeError")),
        };
        match accounts.len() {
            1 => Ok((normalize_account_id(&text(accounts[0].get("name"))), accounts[0].clone())),
            0 => fail("No Fireworks account is available for this API key"),
            _ => fail("Set accountId in fireworks.json when the API key can access multiple accounts"),
        }
    }

    fn usage(&self, account_id: &str, start: NaiveDate, end: NaiveDate) -> Result<Vec<Value>, Failure> {
        let mut query = vec![
            ("startTime", local_midnight_utc(start)),
            ("endTime", local_midnight_utc(end)),
            ("usageType", "SERVERLESS".to_string()),
            ("timezone", timezone_name()),
            ("groupBy", "model_name".to_string()),
        ];
        // 30 days grouped by model can exceed one page; follow the
        // continuation tokens or heavy accounts lose their tail. The bound is
        // a runaway stop.
        let path = format!("{}/billingUsage", Self::account_path(account_id));
        let mut rows = Vec::new();
        for _ in 0..20 {
            let payload = self.request(&path, &query, None)?;
            if let Some(Value::Array(page)) = payload.get("serverlessCosts") {
                rows.extend(page.iter().cloned());
            }
            let token = text(payload.get("nextPageToken"));
            if token.is_empty() {
                break;
            }
            query.retain(|(k, _)| *k != "pageToken");
            query.push(("pageToken", token));
        }
        Ok(rows)
    }

    fn spent(&self, account_id: &str, start_at: &str, end_at: &str) -> Result<Money, Failure> {
        let base = Self::account_path(account_id);
        let body = json!({"startTime": start_at, "endTime": end_at, "scope": "ACCOUNT"});
        let queried = self.request(&format!("{base}/usageCosts:query"), &[], Some(&body)).and_then(|payload| match payload.get("subtotal") {
            Some(subtotal) if subtotal.is_object() => Ok(Money::from_value(Some(subtotal))),
            _ => fail("Fireworks cost response did not include a subtotal"),
        });
        if let Ok(spent) = queried {
            return Ok(spent);
        }
        let end = parse_utc(end_at).ok_or(Failure::Other("ValueError"))?;
        let summary_end = format!("{}T00:00:00Z", day_string(end.date_naive() + chrono::Duration::days(1)));
        let payload = self.request(&format!("{base}/billing/summary"), &[("startTime", start_at.to_string()), ("endTime", summary_end)], None)?;
        let items = match payload.get("lineItems") {
            None => vec![],
            Some(Value::Array(items)) => items.clone(),
            Some(_) => return Err(Failure::Other("TypeError")),
        };
        Ok(Money(items.iter().filter_map(Value::as_object).map(|item| Money::from_value(item.get("totalCost")).0).sum()))
    }
}

/// accounts/{id}:getBalance exists but is permission-gated: keys without the
/// billing role get PERMISSION_DENIED, and then the configured estimate below
/// is the best we can do. The response shape is undocumented, so accept a
/// Money object at the top level or under any plausible field name.
fn live_balance(client: &Client, account_id: &str) -> Option<Money> {
    let payload = Value::Object(client.request(&format!("{}:getBalance", Client::account_path(account_id)), &[], None).ok()?);
    let candidates = std::iter::once(Some(&payload)).chain(["balance", "creditBalance", "prepaidBalance", "amount"].iter().map(|f| payload.get(*f)));
    for value in candidates.flatten() {
        if let Some(map) = value.as_object() {
            if map.contains_key("units") || map.contains_key("nanos") {
                return Some(Money::from_value(Some(value)));
            }
        }
    }
    None
}

/// The configured funding, as Decimal(str(fundedAmount or "0")) reads it
fn funded_amount(config: &Value) -> Result<Money, Decimal> {
    match config.get("fundedAmount") {
        Some(v) if super::truthy(Some(v)) => Money::parse(&match v {
            Value::String(s) => s.clone(),
            Value::Bool(true) => "True".into(),
            other => other.to_string(),
        }),
        _ => Ok(Money::ZERO),
    }
}

fn balance(remaining: Money, funded: Money, spent: Money, estimated: bool) -> Value {
    json!({
        "remaining": remaining.float(),
        "funded": funded.float(),
        "spent": spent.float(),
        "currency": "USD",
        "estimated": estimated,
    })
}

fn estimated_balance(client: &Client, account_id: &str, account: &Map<String, Value>, config: &Value) -> Result<Option<Value>, Failure> {
    let funded = match funded_amount(config) {
        Ok(funded) => funded,
        Err(Decimal::Invalid) => return fail("Fireworks fundedAmount must be a number"),
        Err(Decimal::NotFinite) => return fail("Fireworks fundedAmount must be a finite number"),
    };
    if funded <= Money::ZERO {
        return Ok(None);
    }

    let mut funded_at = iso_timestamp(&text(config.get("fundedAt")))?;
    if funded_at.is_empty() {
        let account = if account.is_empty() { client.request(&Client::account_path(account_id), &[], None)? } else { account.clone() };
        funded_at = iso_timestamp(&text(account.get("createTime")))?;
    }
    if funded_at.is_empty() {
        return fail("Set fundedAt because the Fireworks account creation date is unavailable");
    }

    let end_at = utc_z(Utc::now());
    let spent = client.spent(account_id, &funded_at, &end_at)?;
    let spent = if spent > Money::ZERO { spent } else { Money::ZERO };
    let remaining = Money((funded.0 - spent.0).max(0));
    Ok(Some(balance(remaining, funded, spent, true)))
}

fn scan(base_url: &str, auth_path: &Path) -> Result<Value, Failure> {
    let config = read_json(&config_path()).filter(Value::is_object).unwrap_or(json!({}));
    let (api_key, account_id) = credentials(auth_path, &config);
    if api_key.is_empty() {
        return Ok(base_record(&[("usageStatusText", json!("Fireworks unavailable")), ("authHelpText", json!(AUTH_HELP))]));
    }

    let client = Client { api_key, base_url: base_url.trim_end_matches('/').to_string() };
    let (account_id, account) = if account_id.is_empty() { client.discover_account()? } else { (normalize_account_id(&account_id), Map::new()) };

    let today = super::today();
    let rows = client.usage(&account_id, today - chrono::Duration::days(29), today + chrono::Duration::days(1))?;
    let mut record = base_record(&[("ready", json!(true)), ("hasLocalStats", json!(true))]);
    for (key, value) in summarize_usage(&rows) {
        record[key] = value;
    }

    if let Some(live) = live_balance(&client, &account_id) {
        let funded = match funded_amount(&config) {
            Ok(funded) if funded >= Money::ZERO => funded,
            _ => Money::ZERO,
        };
        let spent = Money((funded.0 - live.0).max(0));
        record["balance"] = balance(live, funded, spent, false);
        return Ok(record);
    }

    match estimated_balance(&client, &account_id, &account, &config) {
        Ok(Some(balance)) => record["balance"] = balance,
        Ok(None) => {}
        Err(Failure::Fireworks(message)) => {
            record["usageStatusText"] = json!("Balance unavailable");
            record["authHelpText"] = json!(message);
        }
        Err(other) => return Err(other),
    }
    Ok(record)
}
