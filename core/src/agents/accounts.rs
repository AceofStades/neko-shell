//! The account registry behind `neko agent account`.
//!
//! An account is a Claude Code, Codex, or Grok login neko keeps a home for.
//! The login you already have stays where the CLI put it (~/.claude,
//! ~/.codex, ~/.grok) and is the primary account; added accounts get a home
//! of their own under ~/.local/state/neko/agents/accounts/<provider>/<id>/
//! that holds only that account's credentials and links everything else back
//! to the primary home, so conversation history, settings and skills stay one
//! set across accounts.
//!
//! Each provider's registry is one JSON file beside those homes. It records
//! which account is active (the one new sessions start as), how switching
//! happens, and display-safe identity. Tokens never enter it and never leave
//! this process.

use std::fs::{self, File};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use base64::Engine;
use chrono::{DateTime, Duration, FixedOffset, TimeZone, Utc};
use serde_json::{json, Map, Value};

use super::{home, now_ms, parse_utc, read_json, resolve, state_root, text, truthy};

struct Provider {
    id: &'static str,
    name: &'static str,
    home_env: &'static str,
    /// Everything a session reads or writes that isn't tied to the login. A
    /// missing directory is made in the primary home first; a missing file is
    /// linked anyway, so whichever account writes it first writes it there.
    shared_dirs: &'static [&'static str],
    shared_files: &'static [&'static str],
    /// Keys copied from the primary's ~/.claude.json into a new account's,
    /// so a second login keeps MCP servers, folder trust and onboarding
    /// choices
    carried_keys: &'static [&'static str],
}

const PROVIDERS: [Provider; 3] = [
    Provider {
        id: "claude",
        name: "Claude",
        home_env: "CLAUDE_CONFIG_DIR",
        shared_dirs: &["projects", "skills", "agents", "commands", "plugins", "hooks", "themes", "output-styles", "file-history", "todos", "plans"],
        shared_files: &["settings.json", "CLAUDE.md", "history.jsonl", "keybindings.json"],
        carried_keys: &["mcpServers", "projects", "theme", "hasCompletedOnboarding", "lastOnboardingVersion", "editorMode"],
    },
    Provider {
        id: "codex",
        name: "Codex",
        home_env: "CODEX_HOME",
        shared_dirs: &["sessions", "archived_sessions", "prompts", "skills", "rules", "plugins"],
        shared_files: &["config.toml", "AGENTS.md", "history.jsonl", "hooks.json"],
        carried_keys: &[],
    },
    Provider {
        id: "grok",
        name: "Grok",
        home_env: "GROK_HOME",
        shared_dirs: &[
            "sessions", "skills", "agents", "plugins", "installed-plugins", "marketplace-cache", "hooks", "memory", "memory-v2", "rules", "commands", "workflows",
            "personas", "worktrees",
        ],
        shared_files: &["config.toml", "settings.json", "lsp.json", "pager.toml", "sandbox.toml", "trusted_folders.toml", "statusline.sh", "worktrees.db"],
        carried_keys: &[],
    },
];

const DEFAULT_THRESHOLD: i64 = 95;
// Ids an account can't take because something else already answers to them:
// `use next` cycles, a provider name is read as the provider when it comes
// first, and the menu's Add Account row is `.add`.
const RESERVED_IDS: [&str; 6] = ["next", "add", "claude", "codex", "grok", "primary"];

type Error = String;

/// Errors are printed as they are, since the commands that call this show
/// them to the user
pub fn run(args: &[String]) -> Result<(), String> {
    if let Err(error) = run_command(args) {
        eprintln!("{error}");
        std::process::exit(1);
    }
    Ok(())
}

fn run_command(args: &[String]) -> Result<(), Error> {
    let Some((command, args)) = args.split_first() else {
        return Err("The account registry behind `neko agent account`.".into());
    };
    let all = || PROVIDERS.iter().collect::<Vec<_>>();
    match command.as_str() {
        "registry" => {
            let provider = provider_arg(args)?;
            println!("{}", summary(provider, &mut load(provider)));
        }
        "list" => {
            let providers = if args.is_empty() { all() } else { vec![provider_arg(args)?] };
            let list: Vec<Value> = providers.into_iter().map(|p| summary(p, &mut load(p))).collect();
            println!("{}", Value::Array(list));
        }
        "home" => {
            // Empty for the primary, so launching it needs no environment
            let provider = provider_arg(args)?;
            if let Some(raw) = read_json(&registry_path(provider)).filter(|r| truthy(Some(r))) {
                let registry = normalized(provider, &raw);
                let account = active(&registry);
                if !truthy(account.get("primary")) {
                    println!("{}", account_home(provider, account).display());
                }
            }
        }
        "homes" => {
            let provider = provider_arg(args)?;
            let registry = load(provider);
            let active_id = &registry["active"];
            for account in accounts(&registry) {
                let flag = if &account["id"] == active_id { "1" } else { "0" };
                println!("{}\t{}\t{flag}", text(account.get("id")), account_home(provider, account).display());
            }
        }
        "refresh" => {
            let providers = if args.is_empty() { all() } else { vec![provider_arg(args)?] };
            for provider in providers {
                if registry_path(provider).exists() {
                    locked(provider, |registry| {
                        refresh_identities(provider, registry);
                        Ok(())
                    })?;
                }
            }
        }
        "begin" => println!("{}", begin(provider_arg(args)?)?.display()),
        "register" => {
            let provider = provider_arg(args)?;
            if args.len() < 3 {
                return Err("register <provider> <label> <pending-home>".into());
            }
            println!("{}", register(provider, &args[1], Path::new(&args[2]))?);
        }
        "use" => {
            let provider = provider_arg(args)?;
            let (previous, account) = use_account(provider, args.get(1).map(String::as_str).unwrap_or("next"))?;
            println!("{}", json!({"previous": previous, "active": account}));
        }
        "remove" => {
            let provider = provider_arg(args)?;
            if args.len() < 2 {
                return Err("remove <provider> <account>".into());
            }
            println!("{}", remove(provider, &args[1])?);
        }
        "rename" => {
            let provider = provider_arg(args)?;
            if args.len() < 3 {
                return Err("rename <provider> <account> <label>".into());
            }
            println!("{}", rename(provider, &args[1], &args[2..].join(" "))?);
        }
        "mode" => {
            let provider = provider_arg(args)?;
            if args.len() < 2 {
                return Err("mode <provider> <manual|auto> [threshold]".into());
            }
            set_mode(provider, &args[1], args.get(2).map(String::as_str))?;
        }
        "link" => {
            let provider = provider_arg(args)?;
            let home = args.get(1).ok_or("link <provider> <home>")?;
            link_shared(provider, Path::new(home)).map_err(|e| e.to_string())?;
        }
        "autoswitch" => {
            // Prints each provider whose active account changed, so the
            // caller knows which usage records to collect again
            let providers = if args.is_empty() { all() } else { vec![provider_arg(args)?] };
            for provider in providers {
                if registry_path(provider).exists() && autoswitch(provider, Utc::now().fixed_offset())? {
                    println!("{}", provider.id);
                }
            }
        }
        other => return Err(format!("Unknown command: {other}")),
    }
    Ok(())
}

fn provider_arg(args: &[String]) -> Result<&'static Provider, Error> {
    args.first().and_then(|name| PROVIDERS.iter().find(|p| p.id == name)).ok_or_else(|| "Name a provider: claude, codex, or grok".to_string())
}

// ------------------------------------------------------------------ paths

fn accounts_root() -> PathBuf {
    state_root().join("accounts")
}

fn registry_path(provider: &Provider) -> PathBuf {
    accounts_root().join(format!("{}.json", provider.id))
}

/// The primary home is where the CLI keeps a login when nothing tells it
/// otherwise. It is deliberately not read from CLAUDE_CONFIG_DIR, CODEX_HOME
/// or GROK_HOME: those are how an added account is selected, so honoring them
/// here would make whichever account launched this command look like the
/// primary.
fn primary_home(provider: &Provider) -> PathBuf {
    home().join(format!(".{}", provider.id))
}

fn account_home(provider: &Provider, account: &Map<String, Value>) -> PathBuf {
    let home = text(account.get("home"));
    if home.is_empty() { primary_home(provider) } else { PathBuf::from(home) }
}

/// Claude keeps its account file beside the config dir for the default home
/// (~/.claude.json) and inside it for any other
fn claude_account_file(home_dir: &Path) -> PathBuf {
    if home_dir == primary_home(&PROVIDERS[0]) { home().join(".claude.json") } else { home_dir.join(".claude.json") }
}

// --------------------------------------------------------------- identity

/// A field of a JSON object that holds an object, or an empty one
fn field(value: Option<&Value>, key: &str) -> Map<String, Value> {
    value.and_then(|v| v.get(key)).and_then(Value::as_object).cloned().unwrap_or_default()
}

fn capitalized(raw: &str) -> String {
    let mut chars = raw.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn plan_label(tier: &str, subscription: &str) -> String {
    let lower = tier.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = lower[from..].find("max_") {
        let start = from + at + 4;
        let digits = lower[start..].chars().take_while(char::is_ascii_digit).count();
        if digits > 0 && lower[start + digits..].starts_with('x') {
            return format!("Max {}", &tier[start..start + digits + 1]);
        }
        from = start;
    }
    capitalized(subscription)
}

fn jwt_claims(token: &str) -> Map<String, Value> {
    let Some(payload) = token.split('.').nth(1) else { return Map::new() };
    let cleaned: String = payload.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(cleaned) else { return Map::new() };
    match serde_json::from_slice::<Value>(&bytes) {
        Ok(Value::Object(claims)) => claims,
        _ => Map::new(),
    }
}

/// Who a home is signed in as, from files the CLI wrote at login. Only
/// display-safe fields come out; an empty accountId means nobody is signed in.
fn identity(provider: &Provider, home_dir: &Path) -> Map<String, Value> {
    let (account_id, email, org, plan) = match provider.id {
        "claude" => {
            let account = field(read_json(&claude_account_file(home_dir)).as_ref(), "oauthAccount");
            let login = field(read_json(&home_dir.join(".credentials.json")).as_ref(), "claudeAiOauth");
            (
                text(account.get("accountUuid")),
                text(account.get("emailAddress")),
                text(account.get("organizationName")),
                plan_label(&text(login.get("rateLimitTier")), &text(login.get("subscriptionType"))),
            )
        }
        // Grok keeps one login per issuer in auth.json, and the plan only in
        // the settings it caches from xAI, as a JSON string inside that file
        "grok" => {
            let auth = read_json(&home_dir.join("auth.json"));
            let login = auth.as_ref().and_then(Value::as_object).and_then(|a| a.values().find_map(|v| v.as_object().cloned())).unwrap_or_default();
            let payload = text(read_json(&home_dir.join("settings_cache.json")).as_ref().and_then(|c| c.get("payload")));
            let settings = serde_json::from_str::<Value>(if payload.is_empty() { "{}" } else { &payload }).ok();
            let plan = text(settings.as_ref().and_then(|s| s.get("settings")).and_then(|s| s.get("subscription_tier_display")));
            (text(login.get("user_id")), text(login.get("email")), String::new(), plan)
        }
        _ => {
            let tokens = field(read_json(&home_dir.join("auth.json")).as_ref(), "tokens");
            let claims = jwt_claims(&text(tokens.get("id_token")));
            let openai = claims.get("https://api.openai.com/auth").and_then(Value::as_object).cloned().unwrap_or_default();
            let account_id = [tokens.get("account_id"), openai.get("chatgpt_account_id")].into_iter().find(|v| truthy(*v)).flatten();
            (text(account_id), text(claims.get("email")), String::new(), capitalized(&text(openai.get("chatgpt_plan_type"))))
        }
    };
    let mut found = Map::new();
    found.insert("accountId".into(), json!(account_id));
    found.insert("email".into(), json!(email));
    found.insert("org".into(), json!(org));
    found.insert("plan".into(), json!(plan));
    found
}

// --------------------------------------------------------------- registry

fn slug(label: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for c in label.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push('-');
            }
            gap = false;
            out.push(c);
        } else {
            gap = true;
        }
    }
    out
}

fn primary_entry(provider: &Provider) -> Value {
    let mut entry = json!({"id": "main", "label": "Main", "home": "", "primary": true});
    entry.as_object_mut().unwrap().extend(identity(provider, &primary_home(provider)));
    entry
}

/// Python's int() of a threshold, or None where it would have raised
fn whole(value: &Value) -> Option<i64> {
    match value {
        Value::Number(n) => n.as_i64().or_else(|| n.as_f64().filter(|f| f.is_finite()).map(|f| f.trunc() as i64)),
        Value::String(s) => s.trim().replace('_', "").parse::<i64>().ok(),
        Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

fn normalized(provider: &Provider, data: &Value) -> Value {
    let mut registry = json!({"active": "main", "switch": "manual", "threshold": DEFAULT_THRESHOLD, "alert": "", "accounts": []});
    if let Some(data) = data.as_object() {
        for key in ["active", "switch", "threshold", "alert", "accounts"] {
            if let Some(value) = data.get(key) {
                registry[key] = value.clone();
            }
        }
    }
    let mut list: Vec<Value> = registry["accounts"].as_array().cloned().unwrap_or_default().into_iter().filter(|a| a.is_object() && truthy(a.get("id"))).collect();
    if !list.iter().any(|a| truthy(a.get("primary"))) {
        list.insert(0, primary_entry(provider));
    }
    registry["accounts"] = Value::Array(list);
    if !matches!(registry["switch"].as_str(), Some("manual" | "auto")) {
        registry["switch"] = json!("manual");
    }
    registry["threshold"] = json!(whole(&registry["threshold"]).map(|t| t.clamp(50, 100)).unwrap_or(DEFAULT_THRESHOLD));
    let active_id = registry["active"].clone();
    if find(&registry, &active_id).is_none() {
        registry["active"] = registry["accounts"][0]["id"].clone();
    }
    registry
}

fn load(provider: &Provider) -> Value {
    normalized(provider, &read_json(&registry_path(provider)).unwrap_or(Value::Null))
}

/// JSON as Python's json.dump(indent=2) wrote it
fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}

/// Written through a temporary file of its own, readable only by you
fn write_private(path: &Path, content: &str) -> std::io::Result<()> {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("registry");
    let tmp = path.with_file_name(format!(".{name}.{}.{}.tmp", std::process::id(), now_ms()));
    let result = (|| {
        let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        file.write_all(content.as_bytes())?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn save(provider: &Provider, registry: &Value) -> std::io::Result<()> {
    let path = registry_path(provider);
    let parent = path.parent().unwrap();
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    write_private(&path, &format!("{}\n", pretty(registry)))
}

/// Every change is read-modify-write under one lock per provider, so the
/// panel, the autoswitch run after each usage update, and a command typed at
/// a prompt can't interleave and drop each other's edits. Saved only when the
/// change went through.
fn locked<T>(provider: &Provider, change: impl FnOnce(&mut Value) -> Result<T, Error>) -> Result<T, Error> {
    let lock_path = accounts_root().join(format!(".{}.lock", provider.id));
    let _lock = super::lock(&lock_path).map_err(|e| e.to_string())?;
    let mut registry = load(provider);
    let result = change(&mut registry)?;
    save(provider, &registry).map_err(|e| e.to_string())?;
    Ok(result)
}

fn accounts(registry: &Value) -> Vec<&Map<String, Value>> {
    registry["accounts"].as_array().into_iter().flatten().filter_map(Value::as_object).collect()
}

/// The index of the account answering to an id: its own, or `primary` for
/// the login that was there first, whatever it's called now
fn find(registry: &Value, account_id: &Value) -> Option<usize> {
    let list = registry["accounts"].as_array()?;
    list.iter().position(|a| a.get("id") == Some(account_id)).or_else(|| {
        if account_id.as_str() == Some("primary") { list.iter().position(|a| truthy(a.get("primary"))) } else { None }
    })
}

fn find_text(registry: &Value, account_id: &str) -> Option<usize> {
    find(registry, &json!(account_id))
}

fn active_index(registry: &Value) -> usize {
    find(registry, &registry["active"]).unwrap_or(0)
}

fn active(registry: &Value) -> &Map<String, Value> {
    registry["accounts"][active_index(registry)].as_object().unwrap()
}

fn account_mut(registry: &mut Value, index: usize) -> &mut Map<String, Value> {
    registry["accounts"][index].as_object_mut().unwrap()
}

fn refresh_identities(provider: &Provider, registry: &mut Value) {
    // Each home is asked who it is now, not trusted from when it was added:
    // a `claude auth login` run by hand in ~/.claude changes the primary
    for account in registry["accounts"].as_array_mut().into_iter().flatten() {
        if let Some(account) = account.as_object_mut() {
            let found = identity(provider, &account_home(provider, account));
            account.extend(found);
        }
    }
}

// ------------------------------------------------------------------ homes

/// Lays the links that make an added account share everything but its login
/// with the primary home. Safe to repeat: an existing link or real file is
/// left as it is, so nothing an account wrote for itself is ever replaced.
fn link_shared(provider: &Provider, home_dir: &Path) -> std::io::Result<()> {
    let primary = primary_home(provider);
    fs::create_dir_all(home_dir)?;
    fs::set_permissions(home_dir, fs::Permissions::from_mode(0o700))?;
    for name in provider.shared_dirs {
        fs::create_dir_all(primary.join(name))?;
    }
    for name in provider.shared_dirs.iter().chain(provider.shared_files) {
        let target = home_dir.join(name);
        if target.exists() || fs::symlink_metadata(&target).is_ok() {
            continue;
        }
        std::os::unix::fs::symlink(primary.join(name), &target)?;
    }
    Ok(())
}

fn carry_settings(provider: &Provider, home_dir: &Path) -> std::io::Result<()> {
    if provider.carried_keys.is_empty() {
        return Ok(());
    }
    let source = read_json(&claude_account_file(&primary_home(provider))).and_then(|s| s.as_object().cloned()).unwrap_or_default();
    let path = claude_account_file(home_dir);
    let mut data = read_json(&path).and_then(|d| d.as_object().cloned()).unwrap_or_default();
    for key in provider.carried_keys {
        if let Some(value) = source.get(*key) {
            data.entry(key.to_string()).or_insert_with(|| value.clone());
        }
    }
    write_private(&path, &pretty(&Value::Object(data)))
}

/// A login in progress gets a scratch home beside the real ones, so an
/// abandoned or duplicate login never shows up as an account
fn begin(provider: &Provider) -> Result<PathBuf, Error> {
    let pending = accounts_root().join(provider.id).join(".pending");
    fs::create_dir_all(&pending).map_err(|e| e.to_string())?;
    fs::set_permissions(pending.parent().unwrap(), fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let home_dir = loop {
        let mut random = [0u8; 6];
        if let Ok(mut urandom) = File::open("/dev/urandom") {
            let _ = std::io::Read::read_exact(&mut urandom, &mut random);
        }
        let suffix: String = random.iter().map(|b| (b'a' + b % 26) as char).collect();
        let candidate = pending.join(format!("login-{suffix}"));
        match fs::create_dir(&candidate) {
            Ok(()) => break candidate,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        }
    };
    fs::set_permissions(&home_dir, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    link_shared(provider, &home_dir).map_err(|e| e.to_string())?;
    Ok(home_dir)
}

fn register(provider: &Provider, label: &str, pending: &Path) -> Result<Value, Error> {
    let pending = resolve(pending);
    if pending.parent() != Some(resolve(&accounts_root().join(provider.id).join(".pending")).as_path()) {
        return Err(format!("{} is not a pending {} login", pending.display(), provider.name));
    }

    let found = identity(provider, &pending);
    if text(found.get("accountId")).is_empty() {
        let _ = fs::remove_dir_all(&pending);
        return Err("The login didn't finish, so no account was added.".into());
    }

    locked(provider, |registry| {
        refresh_identities(provider, registry);
        for account in accounts(registry) {
            if account.get("accountId") == found.get("accountId") {
                let _ = fs::remove_dir_all(&pending);
                let email = text(found.get("email"));
                return Err(format!(
                    "That's {} ({}). Try again, and sign in as the other account in the private window.",
                    text(account.get("label")),
                    if email.is_empty() { "already added" } else { &email }
                ));
            }
        }

        let email = text(found.get("email"));
        let label = match label.trim() {
            "" => match email.split('@').next().unwrap_or("") {
                "" => "Account".to_string(),
                local => local.to_string(),
            },
            given => given.to_string(),
        };
        let account_id = unique_id(provider, registry, &label, None);

        // Everything that can fail happens while the login is still pending,
        // where the add command cleans it up, or is undone: a home that isn't
        // in the registry would keep a sign-in nothing can manage
        carry_settings(provider, &pending).map_err(|e| e.to_string())?;
        let home_dir = accounts_root().join(provider.id).join(&account_id);
        fs::rename(&pending, &home_dir).map_err(|e| e.to_string())?;
        let mut entry = json!({"id": account_id, "label": label, "home": home_dir.to_string_lossy(), "primary": false});
        entry.as_object_mut().unwrap().extend(found.clone());
        registry["accounts"].as_array_mut().unwrap().push(entry.clone());
        if let Err(error) = save(provider, registry) {
            registry["accounts"].as_array_mut().unwrap().pop();
            let _ = fs::rename(&home_dir, &pending);
            return Err(error.to_string());
        }
        Ok(entry)
    })
}

/// The id an account answers to, from its label. It can't clash with
/// another account, a routing keyword, or a home left under that name by an
/// account that has since been renamed.
fn unique_id(provider: &Provider, registry: &Value, label: &str, keep: Option<usize>) -> String {
    let base = match slug(label) {
        s if s.is_empty() => "account".to_string(),
        s => s,
    };
    let mut account_id = base.clone();
    let mut n = 2;
    loop {
        let taken = find_text(registry, &account_id);
        if !RESERVED_IDS.contains(&account_id.as_str()) && (taken.is_none() || taken == keep) && (keep.is_some() || !accounts_root().join(provider.id).join(&account_id).exists()) {
            return account_id;
        }
        account_id = format!("{base}-{n}");
        n += 1;
    }
}

/// A new label, and the id that follows from it. The home stays where it
/// is: sessions already running in it hold that path.
fn rename(provider: &Provider, target: &str, label: &str) -> Result<Value, Error> {
    let label = label.trim();
    if label.is_empty() {
        return Err("Give the account a name".into());
    }
    locked(provider, |registry| {
        let index = find_text(registry, target).ok_or_else(|| format!("No {} account named {target}", provider.name))?;
        let new_id = unique_id(provider, registry, label, Some(index));
        let old_id = registry["accounts"][index]["id"].clone();
        let account = account_mut(registry, index);
        if !truthy(account.get("primary")) && !truthy(account.get("home")) {
            let home_dir = account_home(provider, account);
            account.insert("home".into(), json!(home_dir.to_string_lossy()));
        }
        account.insert("id".into(), json!(new_id));
        account.insert("label".into(), json!(label));
        let renamed = Value::Object(account.clone());
        if registry["active"] == old_id {
            registry["active"] = json!(new_id);
        }
        registry["alert"] = json!("");
        Ok(renamed)
    })
}

fn use_account(provider: &Provider, target: &str) -> Result<(Value, Value), Error> {
    locked(provider, |registry| {
        let previous = Value::Object(active(registry).clone());
        let target = if target == "next" {
            let ids: Vec<Value> = accounts(registry).iter().map(|a| a["id"].clone()).collect();
            let at = ids.iter().position(|id| *id == previous["id"]).unwrap_or(0);
            ids[(at + 1) % ids.len()].clone()
        } else {
            json!(target)
        };
        let index = find(registry, &target).ok_or_else(|| format!("No {} account named {}", provider.name, text(Some(&target))))?;
        let account = Value::Object(registry["accounts"][index].as_object().unwrap().clone());
        registry["active"] = account["id"].clone();
        registry["alert"] = json!("");
        if !truthy(account.get("primary")) {
            link_shared(provider, &account_home(provider, account.as_object().unwrap())).map_err(|e| e.to_string())?;
        }
        Ok((previous, account))
    })
}

/// Whether a running session was started in this home. Removing it would
/// pull the login out from under that session, which must never be touched.
fn home_in_use(provider: &Provider, home_dir: &Path) -> bool {
    let wanted = format!("{}=", provider.home_env);
    let resolved = resolve(home_dir);
    let Ok(entries) = fs::read_dir("/proc") else { return false };
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().chars().next().is_some_and(|c| c.is_ascii_digit()) {
            continue;
        }
        let Ok(environ) = fs::read(entry.path().join("environ")) else { continue };
        for variable in environ.split(|&b| b == 0) {
            if let Some(value) = variable.strip_prefix(wanted.as_bytes()) {
                if resolve(Path::new(&*String::from_utf8_lossy(value))) == resolved {
                    return true;
                }
            }
        }
    }
    false
}

fn remove(provider: &Provider, target: &str) -> Result<Value, Error> {
    locked(provider, |registry| {
        let index = find_text(registry, target).ok_or_else(|| format!("No {} account named {target}", provider.name))?;
        let account = registry["accounts"][index].as_object().unwrap().clone();
        let label = text(account.get("label"));
        if truthy(account.get("primary")) {
            return Err(format!("{label} is the login in {}; it can't be removed here.", primary_home(provider).display()));
        }
        let home_dir = account_home(provider, &account);
        if home_in_use(provider, &home_dir) {
            return Err(format!("A running {} session uses {label}. Quit it first, then remove the account.", provider.name));
        }
        // Only the account's own directory goes. Its links point into the
        // primary home, and removing a directory removes a link without
        // following it.
        if resolve(&home_dir).parent() == Some(resolve(&accounts_root().join(provider.id)).as_path()) {
            let _ = fs::remove_dir_all(&home_dir);
        }
        let list = registry["accounts"].as_array_mut().unwrap();
        list.retain(|a| a.get("id") != account.get("id"));
        if account.get("id") == Some(&registry["active"]) {
            registry["active"] = registry["accounts"][0]["id"].clone();
        }
        Ok(Value::Object(account))
    })
}

fn set_mode(provider: &Provider, mode: &str, threshold: Option<&str>) -> Result<(), Error> {
    if mode != "manual" && mode != "auto" {
        return Err("Switch mode is manual or auto".into());
    }
    locked(provider, |registry| {
        registry["switch"] = json!(mode);
        if let Some(threshold) = threshold {
            let value = whole(&json!(threshold)).ok_or("The threshold is a percentage between 50 and 100")?;
            registry["threshold"] = json!(value.clamp(50, 100));
        }
        registry["alert"] = json!("");
        Ok(())
    })
}

// ------------------------------------------------------------- autoswitch

type Time = DateTime<FixedOffset>;

fn reset_time(limit: &Value) -> Option<Time> {
    parse_utc(&text(limit.get("resetsAt")))
}

fn window_open(limit: &Value, now: Time) -> bool {
    if text(limit.get("resetsAt")).is_empty() {
        return true;
    }
    reset_time(limit).is_none_or(|resets| resets > now)
}

/// The limits that carry a percentage
fn known(limits: Option<&Value>) -> Vec<&Value> {
    limits.and_then(Value::as_array).into_iter().flatten().filter(|l| l.get("percent").is_some_and(Value::is_number)).collect()
}

fn percent(limit: &Value) -> f64 {
    limit["percent"].as_f64().unwrap_or(0.0) * 100.0
}

/// How spent an account is: its fullest window that hasn't reset yet, in
/// percent. A window whose reset has passed counts as empty even when the
/// numbers are stale, since that's exactly what a reset means. None when
/// nothing is known at all.
fn peak(limits: Option<&Value>, now: Time) -> Option<f64> {
    let known = known(limits);
    if known.is_empty() {
        return None;
    }
    let open: Vec<f64> = known.iter().filter(|l| window_open(l, now)).map(|l| percent(l)).collect();
    Some(if open.is_empty() { 0.0 } else { open.into_iter().fold(f64::NEG_INFINITY, f64::max) })
}

fn next_reset(limits: Option<&Value>, now: Time) -> Option<Time> {
    limits.and_then(Value::as_array).into_iter().flatten().filter_map(reset_time).filter(|when| *when > now).min()
}

/// When an account over the threshold drops back under it: once every window
/// holding it there has reset, which is the latest of those resets. A 10%
/// session resetting in an hour doesn't help an account whose weekly window
/// is full for six more days. None when a blocking window never says.
fn available_at(limits: Option<&Value>, threshold: f64, now: Time) -> Option<Time> {
    let mut latest: Option<Time> = None;
    for limit in known(limits).into_iter().filter(|l| l.is_object()) {
        if percent(limit) < threshold || !window_open(limit, now) {
            continue;
        }
        let when = reset_time(limit)?;
        latest = Some(latest.map_or(when, |l| l.max(when)));
    }
    latest
}

fn duration(delta: Duration) -> String {
    let minutes = (delta.num_seconds().div_euclid(60)).max(1);
    let (hours, minutes) = (minutes / 60, minutes % 60);
    let (days, hours) = (hours / 24, hours % 24);
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else {
        format!("{minutes}m")
    }
}

enum Decision {
    Clear,
    Move { switch: bool, alert: String, from: usize, to: usize, from_peak: f64, to_peak: f64 },
    Exhausted { alert: String, from: usize, soonest: Option<(Time, usize)> },
}

/// The whole switching policy, with no I/O: given the registry and the per
/// account limits from the usage record, what should happen.
///
/// Only the active account crossing the threshold starts anything, so auto
/// mode never flaps back to an account that just reset. `alert` remembers the
/// last thing said, so a shell restart or the next refresh doesn't repeat it.
///
/// Numbers kept from an earlier check may be out of date, but a parked
/// account's sign-in lapses within hours and can't be checked again until a
/// session runs in it. So a stale account is still a candidate: among
/// accounts with room, one checked just now wins, but room comes first. An
/// account within 15 points of the threshold is near its limit however fresh
/// its numbers are.
fn decide(registry: &Value, usage: &Map<String, Value>, stale: &[String], now: Time) -> Option<Decision> {
    let threshold = registry["threshold"].as_f64().unwrap_or(DEFAULT_THRESHOLD as f64);
    let list = accounts(registry);
    let current = active_index(registry);
    let limits_of = |index: usize| usage.get(&text(list[index].get("id")));
    let alert_now = text(registry.get("alert"));
    let current_peak = match peak(limits_of(current), now) {
        Some(p) if p >= threshold => p,
        _ => return if alert_now.is_empty() { None } else { Some(Decision::Clear) },
    };

    let far_future = Utc.with_ymd_and_hms(9999, 12, 31, 23, 59, 59).unwrap().fixed_offset();
    let mut candidates: Vec<(bool, bool, f64, Time, usize)> = Vec::new();
    for index in 0..list.len() {
        if list[index].get("id") == list[current].get("id") {
            continue;
        }
        let Some(level) = peak(limits_of(index), now).filter(|l| *l < threshold) else { continue };
        let reset = next_reset(limits_of(index), now).unwrap_or(far_future);
        candidates.push((level >= threshold - 15.0, stale.contains(&text(list[index].get("id"))), level, reset, index));
    }
    candidates.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)).then(a.2.total_cmp(&b.2)).then(a.3.cmp(&b.3)));

    let current_id = text(list[current].get("id"));
    if let Some(&(_, _, level, _, target)) = candidates.first() {
        let switch = registry["switch"] == json!("auto");
        let alert = format!("{}:{current_id}:{}", if switch { "switch" } else { "notify" }, text(list[target].get("id")));
        if alert_now == alert {
            return None;
        }
        return Some(Decision::Move { switch, alert, from: current, to: target, from_peak: current_peak, to_peak: level });
    }

    let alert = format!("exhausted:{current_id}");
    if alert_now == alert || list.len() < 2 {
        return None;
    }
    // Only when every account is known to be over. One that's signed out or
    // couldn't be checked might have room, so there's nothing honest to say.
    if (0..list.len()).any(|index| peak(limits_of(index), now).is_none()) {
        return None;
    }
    let mut soonest: Option<(Time, usize)> = None;
    for index in 0..list.len() {
        if let Some(reset) = available_at(limits_of(index), threshold, now) {
            if soonest.is_none_or(|(at, _)| reset < at) {
                soonest = Some((reset, index));
            }
        }
    }
    Some(Decision::Exhausted { alert, from: current, soonest })
}

/// Limits per account id. An account nobody is signed in to is left out, so
/// it is never a candidate: its cached headroom is no use to a session that
/// can't start. One whose token merely expired stays in, since a session
/// refreshes it.
fn usage_by_account(provider: &Provider) -> (Map<String, Value>, Vec<String>) {
    let record = read_json(&state_root().join("usage").join(format!("{}.json", provider.id))).unwrap_or(Value::Null);
    let list: Vec<&Value> = record
        .get("accounts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|a| a.is_object() && truthy(a.get("id")) && a.get("usageStatusText").and_then(Value::as_str) != Some("Waiting for auth"))
        .collect();
    let usage = list.iter().map(|a| (text(a.get("id")), a.get("limits").cloned().unwrap_or(Value::Null))).collect();
    let stale = list.iter().filter(|a| a.get("stale") == Some(&json!(true))).map(|a| text(a.get("id"))).collect();
    (usage, stale)
}

fn notify(title: &str, body: &str, action: Option<[&str; 3]>) {
    let mut command = Command::new("neko-notification-send");
    command.args(["--app-name", "Neko Agents", "-g", "\u{f06a9}", title, body]);
    if let Some(action) = action {
        command.arg("--exec").args(action);
    }
    let _ = command.status();
}

/// Python's round() of a percentage
fn rounded(value: f64) -> i64 {
    super::round_half_even(value)
}

/// Whether the active account changed
fn autoswitch(provider: &'static Provider, now: Time) -> Result<bool, Error> {
    locked(provider, |registry| {
        if accounts(registry).len() < 2 {
            return Ok(false);
        }
        let (usage, stale) = usage_by_account(provider);
        let Some(decision) = decide(registry, &usage, &stale, now) else { return Ok(false) };
        let name = provider.name;
        let label = |registry: &Value, index: usize| text(registry["accounts"][index].get("label"));
        match decision {
            Decision::Clear => {
                registry["alert"] = json!("");
                Ok(false)
            }
            Decision::Exhausted { alert, from, soonest } => {
                registry["alert"] = json!(alert);
                let when = soonest.map(|(at, index)| format!(" {} resets in {}.", label(registry, index), duration(at - now))).unwrap_or_default();
                let threshold = registry["threshold"].clone();
                notify(&format!("All {name} accounts are over {threshold}%"), &format!("Staying on {}.{when}", label(registry, from)), None);
                Ok(false)
            }
            Decision::Move { switch, alert, from, to, from_peak, to_peak } => {
                registry["alert"] = json!(alert);
                let (source, target) = (label(registry, from), label(registry, to));
                let headline = format!("{source} is at {}% of a {name} limit", rounded(from_peak));
                if switch {
                    let target_account = registry["accounts"][to].as_object().unwrap().clone();
                    registry["active"] = target_account["id"].clone();
                    if !truthy(target_account.get("primary")) {
                        link_shared(provider, &account_home(provider, &target_account)).map_err(|e| e.to_string())?;
                    }
                    notify(&headline, &format!("New {name} sessions now use {target} ({}%). Running sessions stay on {source}.", rounded(to_peak)), None);
                    return Ok(true);
                }
                let target_id = text(registry["accounts"][to].get("id"));
                notify(&headline, &format!("{target} is at {}%. Click to switch new sessions to it.", rounded(to_peak)), Some(["neko-agent-account-use", provider.id, &target_id]));
                Ok(false)
            }
        }
    })
}

// -------------------------------------------------------------------- CLI

/// What the panel and the commands read: identity is re-read from each home
/// rather than trusted from the registry, since a `claude auth login` run by
/// hand in a home changes who it is
fn summary(provider: &Provider, registry: &mut Value) -> Value {
    refresh_identities(provider, registry);
    let active_id = registry["active"].clone();
    let list: Vec<Value> = accounts(registry)
        .into_iter()
        .map(|account| {
            let mut entry = Map::new();
            for key in ["id", "label", "email", "org", "plan", "primary"] {
                entry.insert(key.into(), account.get(key).cloned().unwrap_or(json!("")));
            }
            entry.insert("home".into(), json!(account_home(provider, account).to_string_lossy()));
            entry.insert("active".into(), json!(account.get("id") == Some(&active_id)));
            entry.insert("signedIn".into(), json!(truthy(account.get("accountId"))));
            Value::Object(entry)
        })
        .collect();
    json!({
        "provider": provider.id,
        "name": provider.name,
        "active": registry["active"],
        "switch": registry["switch"],
        "threshold": registry["threshold"],
        "accounts": list,
    })
}

