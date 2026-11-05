//! `neko-core bitwarden`: the Bitwarden vault for the bar's panel, through the
//! official `bw` CLI.
//!
//! `bw` takes seconds a call (it's a Node program), so it runs only to
//! unlock, sync and save. One process holds what that gave: `serve`, run as
//! its own user unit (neko-bitwarden), listening on
//! $XDG_RUNTIME_DIR/neko/bitwarden.sock, which only this user can reach. It
//! keeps the session key and every item in full, so search, copying and the
//! editor are instant; 2FA codes are made here (RFC 6238). All of it is wiped
//! on lock, after the auto-lock time, or when the process ends. Secrets reach
//! `bw` through its environment or stdin, never a command line (anyone's `ps`
//! shows those).
//!
//! Copies are marked sensitive, so clipboard history leaves them out, and
//! cleared after a while if they're still there.
//!
//! Quicker unlocks, each set in the panel's settings:
//!   PIN          after one unlock with the master password, the password is
//!                kept in this process's memory (never on disk) and a PIN,
//!                stored as a salted PBKDF2 hash, unlocks again; five wrong
//!                PINs forget it. It doesn't outlive the process.
//!   face/finger  the master password is kept in the login keyring (Secret
//!                Service, through secret-tool); the panel checks the face or
//!                finger through PAM first, as the lock screen does, and then
//!                asks for `unlock-keyring`
//!
//!   status                    the vault's state, the account and the settings
//!   unlock                    with the master password on stdin
//!   unlock-pin                with the PIN on stdin
//!   unlock-keyring            with the password the keyring kept
//!   lock | sync | items | folders
//!   item <id>                 one item in full, for the editor
//!   save                      an item's fields as JSON on stdin (an id edits)
//!   delete <id>               into Bitwarden's trash
//!   generate [length]         a random password
//!   copy <id> <field>         username, password, totp or uri
//!   open <id>                 the item's first site, in the browser
//!   set <name> <value>        a setting: autolock, clear, lockOnScreenLock,
//!                             face, fingerprint
//!   pin [<pin> on stdin]      set the PIN, or with nothing given remove it
//!   lock-for-screen           lock if the settings say to on a screen lock
//!   serve                     the holder (neko-bitwarden.service)

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::{self, sleep};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha512};

const UNIT: &str = "neko-bitwarden";
const KEYRING_SERVICE: &str = "neko-bitwarden";
const PIN_ROUNDS: u32 = 210_000;
const PIN_TRIES: u32 = 5;

/// A string wiped from memory when dropped
struct Secret(String);

impl Drop for Secret {
    fn drop(&mut self) {
        // Safety: zeroes keep the bytes valid UTF-8
        unsafe { self.0.as_bytes_mut().fill(0) };
    }
}

impl Clone for Secret {
    fn clone(&self) -> Self {
        Secret(self.0.clone())
    }
}

fn wipe(bytes: &mut Vec<u8>) {
    bytes.fill(0);
}

/// Overwrites every string in a JSON value, so what it held doesn't linger
fn blank_strings(value: &mut Value) {
    match value {
        Value::String(text) => unsafe { text.as_bytes_mut().fill(0) },
        Value::Array(values) => values.iter_mut().for_each(blank_strings),
        Value::Object(map) => map.values_mut().for_each(blank_strings),
        _ => {}
    }
}

fn runtime_dir() -> PathBuf {
    std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir()).join("neko")
}

fn socket_path() -> PathBuf {
    runtime_dir().join("bitwarden.sock")
}

fn settings_path() -> PathBuf {
    let base = std::env::var("XDG_STATE_HOME")
        .ok()
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("neko/bitwarden.json")
}

fn random_bytes(count: usize) -> Vec<u8> {
    let mut bytes = vec![0u8; count];
    if let Ok(mut source) = fs::File::open("/dev/urandom") {
        let _ = source.read_exact(&mut bytes);
    }
    bytes
}

// ---------------------------------------------------------------- settings

struct Settings {
    /// Minutes idle before it locks; 0 never
    autolock: u64,
    /// Seconds before a copy is cleared; 0 never
    clear: u64,
    lock_on_screen_lock: bool,
    face: bool,
    fingerprint: bool,
    /// The PIN's salt and PBKDF2 hash, hex
    pin_salt: String,
    pin_hash: String,
}

impl Settings {
    fn load() -> Settings {
        let saved = fs::read_to_string(settings_path()).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()).unwrap_or(json!({}));
        let number = |name: &str, fallback: u64| saved.get(name).and_then(Value::as_u64).unwrap_or(fallback);
        let flag = |name: &str| saved.get(name).and_then(Value::as_bool).unwrap_or(false);
        let text = |name: &str| saved.get(name).and_then(Value::as_str).unwrap_or("").to_string();
        Settings {
            autolock: number("autolock", 15),
            clear: number("clear", 30),
            lock_on_screen_lock: saved.get("lockOnScreenLock").and_then(Value::as_bool).unwrap_or(true),
            // "remember" was face unlock's first name
            face: flag("face") || flag("remember"),
            fingerprint: flag("fingerprint"),
            pin_salt: text("pinSalt"),
            pin_hash: text("pinHash"),
        }
    }

    fn save(&self) {
        let path = settings_path();
        if let Some(dir) = path.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let value = json!({
            "autolock": self.autolock,
            "clear": self.clear,
            "lockOnScreenLock": self.lock_on_screen_lock,
            "face": self.face,
            "fingerprint": self.fingerprint,
            "pinSalt": self.pin_salt,
            "pinHash": self.pin_hash,
        });
        let _ = fs::write(&path, serde_json::to_string_pretty(&value).unwrap_or_default());
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }

    fn keyring_wanted(&self) -> bool {
        self.face || self.fingerprint
    }

    fn pin_set(&self) -> bool {
        !self.pin_hash.is_empty()
    }
}

// ------------------------------------------------------------- hashing

fn hmac(key: &[u8], message: &[u8], block: usize, hash: fn(&[u8]) -> Vec<u8>) -> Vec<u8> {
    let mut key = if key.len() > block { hash(key) } else { key.to_vec() };
    key.resize(block, 0);
    let inner: Vec<u8> = key.iter().map(|byte| byte ^ 0x36).chain(message.iter().copied()).collect();
    let outer: Vec<u8> = key.iter().map(|byte| byte ^ 0x5c).chain(hash(&inner)).collect();
    hash(&outer)
}

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

/// PBKDF2-HMAC-SHA256, one block (RFC 8018)
fn pbkdf2(password: &[u8], salt: &[u8], rounds: u32) -> Vec<u8> {
    let mut first = salt.to_vec();
    first.extend_from_slice(&1u32.to_be_bytes());
    let mut u = hmac(password, &first, 64, sha256);
    let mut out = u.clone();
    for _ in 1..rounds {
        u = hmac(password, &u, 64, sha256);
        out.iter_mut().zip(&u).for_each(|(a, b)| *a ^= b);
    }
    out
}

fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

// -------------------------------------------------------------------- totp

/// RFC 4648 base32, as 2FA secrets are written: case and spaces ignored
fn base32(text: &str) -> Option<Vec<u8>> {
    let mut bits = 0u32;
    let mut count = 0;
    let mut out = Vec::new();
    for c in text.chars().filter(|c| !c.is_whitespace() && *c != '=' && *c != '-') {
        let value = match c.to_ascii_uppercase() {
            letter @ 'A'..='Z' => letter as u32 - 'A' as u32,
            digit @ '2'..='7' => digit as u32 - '2' as u32 + 26,
            _ => return None,
        };
        bits = (bits << 5) | value;
        count += 5;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
        }
    }
    (!out.is_empty()).then_some(out)
}

/// The code a 2FA secret gives now: a bare base32 secret (SHA-1, 6 digits,
/// 30 seconds), or an otpauth:// URI naming its own. None for what it can't
/// make (Steam's codes), which `bw` then makes instead.
fn totp_code(entry: &str, now_s: u64) -> Option<String> {
    let (mut secret, mut algorithm, mut digits, mut period) = (entry.to_string(), "SHA1".to_string(), 6u32, 30u64);
    if let Some(query) = entry.strip_prefix("otpauth://").and_then(|rest| rest.split_once('?')).map(|(_, query)| query) {
        secret.clear();
        for pair in query.split('&') {
            let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
            match name.to_ascii_lowercase().as_str() {
                "secret" => secret = value.to_string(),
                "algorithm" => algorithm = value.to_ascii_uppercase(),
                "digits" => digits = value.parse().unwrap_or(6),
                "period" => period = value.parse().unwrap_or(30),
                _ => {}
            }
        }
    } else if entry.contains("://") {
        return None;
    }
    if period == 0 || !(6..=10).contains(&digits) {
        return None;
    }
    let key = base32(&secret)?;
    let counter = (now_s / period).to_be_bytes();
    let mac = match algorithm.as_str() {
        "SHA1" => hmac(&key, &counter, 64, |data| Sha1::digest(data).to_vec()),
        "SHA256" => hmac(&key, &counter, 64, sha256),
        "SHA512" => hmac(&key, &counter, 128, |data| Sha512::digest(data).to_vec()),
        _ => return None,
    };
    let offset = (mac.last()? & 0x0f) as usize;
    let number = u32::from_be_bytes([mac[offset] & 0x7f, mac[offset + 1], mac[offset + 2], mac[offset + 3]]);
    Some(format!("{:0width$}", number % 10u32.pow(digits), width = digits as usize))
}

/// A random password: letters, and digits and symbols unless left out
fn generate(length: usize, digits: bool, symbols: bool) -> String {
    let mut alphabet: Vec<char> = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".chars().collect();
    if digits {
        alphabet.extend("23456789".chars());
    }
    if symbols {
        alphabet.extend("!@#$%^&*-_=+?".chars());
    }
    let mut out = String::new();
    // Rejection sampling, so every character is as likely as the next
    let limit = 256 - 256 % alphabet.len();
    while out.chars().count() < length.clamp(8, 128) {
        for byte in random_bytes(64) {
            if (byte as usize) < limit && out.chars().count() < length.clamp(8, 128) {
                out.push(alphabet[byte as usize % alphabet.len()]);
            }
        }
    }
    out
}

// ------------------------------------------------------------------ bw

/// Runs `bw` with the session key in its environment and anything given on
/// its stdin; its output, or what it said went wrong
fn bw(args: &[&str], session: Option<&Secret>, extra_env: Option<(&str, &Secret)>, input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let mut command = Command::new("bw");
    command
        .args(args)
        .env("BW_NOINTERACTION", "true")
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(key) = session {
        command.env("BW_SESSION", &key.0);
    }
    if let Some((name, value)) = extra_env {
        command.env(name, &value.0);
    }
    let mut child = command.spawn().map_err(|error| format!("can't run bw: {error}"))?;
    if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
        let _ = stdin.write_all(bytes);
    }
    let output = child.wait_with_output().map_err(|error| format!("bw failed: {error}"))?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let said = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let mut stdout = output.stdout;
    wipe(&mut stdout);
    Err(if said.is_empty() { format!("bw {} failed", args.first().unwrap_or(&"")) } else { said })
}

fn bw_json(args: &[&str], session: &Secret, input: Option<&[u8]>) -> Result<Value, String> {
    let mut raw = bw(args, Some(session), None, input)?;
    let parsed = serde_json::from_slice(&raw).map_err(|error| format!("can't read what bw said: {error}"));
    wipe(&mut raw);
    parsed
}

/// What the panel's list shows of an item: nothing secret
fn summary(item: &Value) -> Value {
    let login = item.get("login");
    let uri = login
        .and_then(|login| login.get("uris"))
        .and_then(Value::as_array)
        .and_then(|uris| uris.first())
        .and_then(|uri| uri.get("uri"))
        .cloned()
        .unwrap_or(Value::Null);
    let present = |value: Option<&Value>| value.is_some_and(|value| value.as_str().is_some_and(|text| !text.is_empty()));
    json!({
        "id": item.get("id"),
        "name": item.get("name"),
        // 1 login, 2 note, 3 card, 4 identity, 5 SSH key
        "type": item.get("type"),
        "favorite": item.get("favorite").and_then(Value::as_bool).unwrap_or(false),
        "folderId": item.get("folderId"),
        "username": login.and_then(|login| login.get("username")).cloned().unwrap_or(Value::Null),
        "uri": uri,
        "hasPassword": present(login.and_then(|login| login.get("password"))),
        "hasTotp": present(login.and_then(|login| login.get("totp"))),
    })
}

/// What the editor shows of an item, secrets included
fn editable(item: &Value) -> Value {
    let login = item.get("login");
    let text = |value: Option<&Value>| value.and_then(Value::as_str).unwrap_or("").to_string();
    json!({
        "id": item.get("id"),
        "type": item.get("type"),
        "name": text(item.get("name")),
        "username": text(login.and_then(|login| login.get("username"))),
        "password": text(login.and_then(|login| login.get("password"))),
        "totp": text(login.and_then(|login| login.get("totp"))),
        "uri": text(login.and_then(|login| login.get("uris")).and_then(Value::as_array).and_then(|uris| uris.first()).and_then(|uri| uri.get("uri"))),
        "notes": text(item.get("notes")),
        "folderId": item.get("folderId").cloned().unwrap_or(Value::Null),
        "favorite": item.get("favorite").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// The editor's fields laid onto an item, or onto a new login or note
fn apply_fields(base: Option<&Value>, fields: &Value) -> Value {
    let mut item = base.cloned().unwrap_or_else(|| {
        let kind = fields.get("type").and_then(Value::as_u64).unwrap_or(1);
        json!({
            "organizationId": null,
            "collectionIds": null,
            "folderId": null,
            "type": kind,
            "name": "",
            "notes": null,
            "favorite": false,
            "fields": [],
            "login": if kind == 1 { json!({ "uris": [], "username": null, "password": null, "totp": null }) } else { Value::Null },
            "secureNote": if kind == 2 { json!({ "type": 0 }) } else { Value::Null },
            "card": null,
            "identity": null,
            "reprompt": 0,
        })
    });
    let text = |name: &str| fields.get(name).and_then(Value::as_str).map(str::to_string);
    let nullable = |value: Option<String>| value.filter(|text| !text.is_empty()).map(Value::String).unwrap_or(Value::Null);
    if let Some(name) = text("name") {
        item["name"] = Value::String(name);
    }
    if fields.get("notes").is_some() {
        item["notes"] = nullable(text("notes"));
    }
    if let Some(favorite) = fields.get("favorite").and_then(Value::as_bool) {
        item["favorite"] = Value::Bool(favorite);
    }
    if fields.get("folderId").is_some() {
        item["folderId"] = nullable(text("folderId"));
    }
    if item.get("type").and_then(Value::as_u64) == Some(1) {
        if !item.get("login").is_some_and(Value::is_object) {
            item["login"] = json!({});
        }
        let login = &mut item["login"];
        for field in ["username", "password", "totp"] {
            if fields.get(field).is_some() {
                login[field] = nullable(text(field));
            }
        }
        if let Some(uri) = text("uri") {
            let mut uris = login.get("uris").and_then(Value::as_array).cloned().unwrap_or_default();
            if uri.is_empty() {
                if !uris.is_empty() {
                    uris.remove(0);
                }
            } else if let Some(first) = uris.first_mut() {
                first["uri"] = Value::String(uri);
            } else {
                uris.push(json!({ "match": null, "uri": uri }));
            }
            login["uris"] = Value::Array(uris);
        }
    }
    item
}

// ------------------------------------------------------------- clipboard

/// Copies, marked sensitive, and clears it after a while if it's unchanged
fn copy_sensitive(value: Secret, clear_after: u64) -> Result<(), String> {
    let mut child = Command::new("wl-copy")
        .args(["--sensitive", "--trim-newline"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("can't run wl-copy: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(value.0.as_bytes()).map_err(|error| format!("can't copy: {error}"))?;
    }
    child.wait().map_err(|error| format!("wl-copy failed: {error}"))?;
    if clear_after == 0 {
        return Ok(());
    }
    thread::spawn(move || {
        sleep(Duration::from_secs(clear_after));
        if let Ok(mut output) = Command::new("wl-paste").arg("--no-newline").stderr(Stdio::null()).output() {
            if output.stdout == value.0.as_bytes() {
                let _ = Command::new("wl-copy").arg("--clear").status();
            }
            wipe(&mut output.stdout);
        }
        drop(value);
    });
    Ok(())
}

// ---------------------------------------------------------------- keyring

fn keyring_store(account: &str, password: &Secret) -> Result<(), String> {
    let mut child = Command::new("secret-tool")
        .args(["store", "--label=neko: Bitwarden master password", "service", KEYRING_SERVICE, "account", account])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("can't run secret-tool: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(password.0.as_bytes()).map_err(|error| format!("can't reach the keyring: {error}"))?;
    }
    let status = child.wait().map_err(|error| format!("secret-tool failed: {error}"))?;
    if status.success() { Ok(()) } else { Err("the keyring refused the password".into()) }
}

fn keyring_lookup(account: &str) -> Result<Secret, String> {
    let output = Command::new("secret-tool")
        .args(["lookup", "service", KEYRING_SERVICE, "account", account])
        .stderr(Stdio::null())
        .output()
        .map_err(|error| format!("can't run secret-tool: {error}"))?;
    if !output.status.success() || output.stdout.is_empty() {
        return Err("unlock once with the master password first; the keyring keeps it from then on".into());
    }
    String::from_utf8(output.stdout).map(|text| Secret(text.trim_end_matches('\n').to_string())).map_err(|_| "the kept password isn't text".into())
}

fn keyring_has(account: &str) -> bool {
    Command::new("secret-tool")
        .args(["lookup", "service", KEYRING_SERVICE, "account", account])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn keyring_clear(account: &str) {
    let _ = Command::new("secret-tool").args(["clear", "service", KEYRING_SERVICE, "account", account]).status();
}

/// Whether a face (Howdy in the login's PAM stack) or a finger (neko's
/// fingerprint profile, with one enrolled) can be checked here
fn biometrics() -> (bool, bool) {
    let face = std::path::Path::new("/usr/lib/security/pam_howdy.so").exists()
        && fs::read_to_string("/etc/pam.d/system-auth").is_ok_and(|text| {
            text.lines().any(|line| line.trim_start().starts_with("auth") && line.contains("pam_howdy.so"))
        });
    let finger = std::path::Path::new("/etc/pam.d/neko-lock-fingerprint").exists()
        && Command::new("fprintd-list")
            .arg(std::env::var("USER").unwrap_or_default())
            .output()
            .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("finger"));
    (face, finger)
}

// ---------------------------------------------------------------- server

struct Vault {
    session: Option<Secret>,
    /// Every item in full, by id: wiped on lock
    items: HashMap<String, Value>,
    folders: Vec<Value>,
    /// The master password, kept in memory only while a PIN is set
    master: Option<Secret>,
    pin_misses: u32,
    /// The account's email, or empty when logged out
    account: String,
    logged_in: bool,
    last_used: Instant,
    settings: Settings,
    face_available: bool,
    finger_available: bool,
}

impl Vault {
    fn read_status(&mut self) {
        if let Ok(mut raw) = bw(&["status"], self.session.as_ref(), None, None) {
            if let Ok(status) = serde_json::from_slice::<Value>(&raw) {
                self.account = status.get("userEmail").and_then(Value::as_str).unwrap_or("").to_string();
                self.logged_in = status.get("status").and_then(Value::as_str) != Some("unauthenticated");
            }
            wipe(&mut raw);
        }
    }

    fn status(&self) -> Value {
        let keyring = self.settings.keyring_wanted() && !self.account.is_empty() && keyring_has(&self.account);
        json!({
            "ok": true,
            "state": if !self.logged_in { "logged-out" } else if self.session.is_some() { "unlocked" } else { "locked" },
            "account": self.account,
            "count": self.items.len(),
            "settings": {
                "autolock": self.settings.autolock,
                "clear": self.settings.clear,
                "lockOnScreenLock": self.settings.lock_on_screen_lock,
                "face": self.settings.face,
                "fingerprint": self.settings.fingerprint,
                "pin": self.settings.pin_set(),
            },
            // What can unlock it now, besides the master password
            "can": {
                "pin": self.settings.pin_set() && self.master.is_some(),
                "face": self.settings.face && self.face_available && keyring,
                "fingerprint": self.settings.fingerprint && self.finger_available && keyring,
            },
            "available": { "face": self.face_available, "fingerprint": self.finger_available },
        })
    }

    fn forget_items(&mut self) {
        for item in self.items.values_mut() {
            blank_strings(item);
        }
        self.items.clear();
        self.folders.clear();
    }

    fn lock(&mut self) {
        if let Some(session) = self.session.take() {
            let _ = bw(&["lock"], Some(&session), None, None);
        }
        self.forget_items();
    }

    /// Lists the vault and its folders at once, each bw taking seconds
    fn load(&mut self, session: &Secret) -> Result<(), String> {
        let (items, folders) = thread::scope(|scope| {
            let folders = scope.spawn(|| bw_json(&["list", "folders"], session, None));
            (bw_json(&["list", "items"], session, None), folders.join().unwrap_or_else(|_| Err("bw failed".into())))
        });
        self.forget_items();
        let mut items = items?;
        for item in items.as_array().into_iter().flatten() {
            if let Some(id) = item.get("id").and_then(Value::as_str) {
                self.items.insert(id.to_string(), item.clone());
            }
        }
        blank_strings(&mut items);
        self.folders = folders
            .ok()
            .and_then(|folders| folders.as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter(|folder| folder.get("id").is_some_and(|id| !id.is_null()))
            .map(|folder| json!({ "id": folder.get("id"), "name": folder.get("name") }))
            .collect();
        Ok(())
    }

    fn unlock(&mut self, password: Secret) -> Result<Value, String> {
        let mut raw = bw(&["unlock", "--raw", "--passwordenv", "NEKO_BW_PASSWORD"], None, Some(("NEKO_BW_PASSWORD", &password)), None)?;
        let key = Secret(String::from_utf8_lossy(&raw).trim().to_string());
        wipe(&mut raw);
        if key.0.is_empty() {
            return Err("bw gave no session key".into());
        }
        self.load(&key)?;
        self.session = Some(key);
        self.pin_misses = 0;
        if self.settings.pin_set() {
            self.master = Some(password.clone());
        }
        if self.settings.keyring_wanted() && !self.account.is_empty() {
            keyring_store(&self.account, &password)?;
        }
        Ok(self.status())
    }

    fn item(&self, id: &str) -> Result<&Value, String> {
        self.items.get(id).ok_or_else(|| "no such item".to_string())
    }

    fn handle(&mut self, request: &Value) -> Result<Value, String> {
        let verb = request.get("verb").and_then(Value::as_str).unwrap_or("");
        let text = |name: &str| request.get(name).and_then(Value::as_str).unwrap_or("").to_string();
        if verb != "status" && verb != "lock-for-screen" {
            self.last_used = Instant::now();
        }
        match verb {
            "status" => Ok(self.status()),
            "unlock" => {
                let password = Secret(text("password"));
                if password.0.is_empty() {
                    return Err("no password given".into());
                }
                self.unlock(password)
            }
            "unlock-pin" => {
                let pin = Secret(text("pin"));
                let master = self.master.clone().ok_or("unlock with the master password first; the PIN works from then on")?;
                let salt = hex::decode(&self.settings.pin_salt).map_err(|_| "the PIN isn't set")?;
                let hash = hex::decode(&self.settings.pin_hash).map_err(|_| "the PIN isn't set")?;
                if !same(&pbkdf2(pin.0.as_bytes(), &salt, PIN_ROUNDS), &hash) {
                    self.pin_misses += 1;
                    if self.pin_misses >= PIN_TRIES {
                        self.master = None;
                        return Err("Too many wrong PINs; unlock with the master password".into());
                    }
                    return Err(format!("Wrong PIN ({} left)", PIN_TRIES - self.pin_misses));
                }
                self.unlock(master)
            }
            "unlock-keyring" => {
                let password = keyring_lookup(&self.account)?;
                self.unlock(password)
            }
            "lock" => {
                self.lock();
                Ok(self.status())
            }
            "lock-for-screen" => {
                if self.settings.lock_on_screen_lock {
                    self.lock();
                }
                Ok(self.status())
            }
            "sync" => {
                let session = self.session.clone().ok_or("the vault is locked")?;
                bw(&["sync"], Some(&session), None, None)?;
                self.load(&session)?;
                Ok(self.status())
            }
            "items" => {
                if self.session.is_none() {
                    return Err("the vault is locked".into());
                }
                Ok(json!({ "ok": true, "items": self.items.values().map(summary).collect::<Vec<_>>() }))
            }
            "folders" => {
                if self.session.is_none() {
                    return Err("the vault is locked".into());
                }
                Ok(json!({ "ok": true, "folders": self.folders }))
            }
            "item" => {
                if self.session.is_none() {
                    return Err("the vault is locked".into());
                }
                Ok(json!({ "ok": true, "item": editable(self.item(&text("id"))?) }))
            }
            "save" => {
                let session = self.session.clone().ok_or("the vault is locked")?;
                let fields = request.get("fields").cloned().unwrap_or(json!({}));
                let id = fields.get("id").and_then(Value::as_str).filter(|id| !id.is_empty()).map(str::to_string);
                if fields.get("name").and_then(Value::as_str).is_some_and(|name| name.trim().is_empty()) {
                    return Err("an item needs a name".into());
                }
                let base = id.as_deref().map(|id| self.item(id)).transpose()?;
                let mut item = apply_fields(base, &fields);
                let mut encoded = base64::engine::general_purpose::STANDARD.encode(item.to_string()).into_bytes();
                blank_strings(&mut item);
                let saved = match &id {
                    Some(id) => bw_json(&["edit", "item", id], &session, Some(&encoded)),
                    None => bw_json(&["create", "item"], &session, Some(&encoded)),
                };
                wipe(&mut encoded);
                let saved = saved?;
                let saved_id = saved.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                if let Some(mut old) = self.items.insert(saved_id.clone(), saved) {
                    blank_strings(&mut old);
                }
                Ok(json!({ "ok": true, "id": saved_id }))
            }
            "delete" => {
                let session = self.session.clone().ok_or("the vault is locked")?;
                let id = text("id");
                self.item(&id)?;
                bw(&["delete", "item", &id], Some(&session), None, None)?;
                if let Some(mut old) = self.items.remove(&id) {
                    blank_strings(&mut old);
                }
                Ok(json!({ "ok": true }))
            }
            "generate" => {
                let length = request.get("length").and_then(Value::as_u64).unwrap_or(20) as usize;
                let digits = request.get("digits").and_then(Value::as_bool).unwrap_or(true);
                let symbols = request.get("symbols").and_then(Value::as_bool).unwrap_or(true);
                Ok(json!({ "ok": true, "password": generate(length, digits, symbols) }))
            }
            "copy" => {
                let id = text("id");
                let field = text("field");
                let session = self.session.clone().ok_or("the vault is locked")?;
                let item = self.item(&id)?;
                let full = editable(item);
                let value = match field.as_str() {
                    "username" | "uri" | "password" => Secret(full.get(&field).and_then(Value::as_str).unwrap_or("").to_string()),
                    "totp" => {
                        let entry = full.get("totp").and_then(Value::as_str).unwrap_or("").to_string();
                        if entry.is_empty() {
                            return Err("this item has no 2FA code".into());
                        }
                        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_secs()).unwrap_or(0);
                        match totp_code(&entry, now) {
                            Some(code) => Secret(code),
                            // One it can't make here: bw makes it
                            None => {
                                let mut raw = bw(&["get", "totp", &id], Some(&session), None, None)?;
                                let code = Secret(String::from_utf8_lossy(&raw).trim().to_string());
                                wipe(&mut raw);
                                code
                            }
                        }
                    }
                    _ => return Err(format!("can't copy {field}")),
                };
                let mut full = full;
                blank_strings(&mut full);
                if value.0.is_empty() {
                    return Err(format!("this item has no {field}"));
                }
                copy_sensitive(value, self.settings.clear)?;
                Ok(json!({ "ok": true, "clearsIn": self.settings.clear }))
            }
            "open" => {
                let item = self.item(&text("id"))?;
                let uri = summary(item).get("uri").and_then(Value::as_str).map(str::to_string).ok_or("this item has no site")?;
                let uri = if uri.contains("://") { uri } else { format!("https://{uri}") };
                Command::new("xdg-open").arg(uri).spawn().map_err(|error| format!("can't open it: {error}"))?;
                Ok(json!({ "ok": true }))
            }
            "set" => {
                let name = text("name");
                let value = request.get("value").cloned().unwrap_or(Value::Null);
                match name.as_str() {
                    "autolock" => self.settings.autolock = value.as_u64().ok_or("autolock takes minutes")?,
                    "clear" => self.settings.clear = value.as_u64().ok_or("clear takes seconds")?,
                    "lockOnScreenLock" => self.settings.lock_on_screen_lock = value.as_bool().unwrap_or(false),
                    "face" => self.settings.face = value.as_bool().unwrap_or(false),
                    "fingerprint" => self.settings.fingerprint = value.as_bool().unwrap_or(false),
                    other => return Err(format!("no setting {other}")),
                }
                // Turned on while unlocked, a biometric needs the password now:
                // there's none to keep, so it waits for the next unlock
                if !self.settings.keyring_wanted() && !self.account.is_empty() {
                    keyring_clear(&self.account);
                }
                self.settings.save();
                Ok(self.status())
            }
            "pin" => {
                let pin = Secret(text("pin"));
                if pin.0.is_empty() {
                    self.settings.pin_salt.clear();
                    self.settings.pin_hash.clear();
                    self.master = None;
                } else {
                    if pin.0.chars().count() < 4 {
                        return Err("a PIN needs at least 4 characters".into());
                    }
                    let salt = random_bytes(16);
                    self.settings.pin_hash = hex::encode(pbkdf2(pin.0.as_bytes(), &salt, PIN_ROUNDS));
                    self.settings.pin_salt = hex::encode(salt);
                    self.pin_misses = 0;
                }
                self.settings.save();
                Ok(self.status())
            }
            other => Err(format!("unknown request: {other}")),
        }
    }
}

fn serve() -> Result<(), String> {
    let path = socket_path();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|error| format!("can't create {}: {error}", dir.display()))?;
    }
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path).map_err(|error| format!("can't listen on {}: {error}", path.display()))?;
    let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    listener.set_nonblocking(true).map_err(|error| error.to_string())?;

    let (face_available, finger_available) = biometrics();
    let mut vault = Vault {
        session: None,
        items: HashMap::new(),
        folders: Vec::new(),
        master: None,
        pin_misses: 0,
        account: String::new(),
        logged_in: false,
        last_used: Instant::now(),
        settings: Settings::load(),
        face_available,
        finger_available,
    };
    vault.read_status();

    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                let reply = match reader.read_line(&mut line) {
                    Ok(_) => match serde_json::from_str::<Value>(&line) {
                        Ok(mut request) => {
                            let reply = vault.handle(&request).unwrap_or_else(|error| json!({ "ok": false, "error": error }));
                            blank_strings(&mut request);
                            reply
                        }
                        Err(_) => json!({ "ok": false, "error": "not a request" }),
                    },
                    Err(error) => json!({ "ok": false, "error": error.to_string() }),
                };
                // The request may have carried the master password or a PIN
                unsafe { line.as_bytes_mut().fill(0) };
                let mut stream = stream;
                let mut reply = reply;
                let _ = writeln!(stream, "{reply}");
                blank_strings(&mut reply);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                sleep(Duration::from_millis(100));
                let idle = vault.settings.autolock;
                if vault.session.is_some() && idle > 0 && vault.last_used.elapsed() > Duration::from_secs(idle * 60) {
                    vault.lock();
                }
            }
            Err(error) => return Err(format!("can't accept: {error}")),
        }
    }
}

// ---------------------------------------------------------------- client

/// Starts the holder as its own user unit when it isn't up, and waits for it
fn ensure_server() -> Result<(), String> {
    if UnixStream::connect(socket_path()).is_ok() {
        return Ok(());
    }
    let program = std::env::current_exe().map_err(|error| format!("can't find neko-core: {error}"))?;
    let mut command = Command::new("systemd-run");
    command.args(["--user", "--quiet", "--collect", &format!("--unit={UNIT}")]);
    for name in ["PATH", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "BITWARDENCLI_APPDATA_DIR", "USER"] {
        if let Ok(value) = std::env::var(name) {
            command.arg(format!("--setenv={name}={value}"));
        }
    }
    command.arg(program).args(["bitwarden", "serve"]).stdout(Stdio::null()).stderr(Stdio::null());
    let _ = command.status();
    // `bw status` runs as it starts, which can take a moment
    for _ in 0..100 {
        if UnixStream::connect(socket_path()).is_ok() {
            return Ok(());
        }
        sleep(Duration::from_millis(100));
    }
    Err("the Bitwarden helper didn't start".into())
}

fn request(body: Value) -> Result<(), String> {
    ensure_server()?;
    let mut stream = UnixStream::connect(socket_path()).map_err(|error| format!("can't reach the Bitwarden helper: {error}"))?;
    let mut body = body;
    writeln!(stream, "{body}").map_err(|error| error.to_string())?;
    blank_strings(&mut body);
    let mut reply = String::new();
    stream.read_to_string(&mut reply).map_err(|error| error.to_string())?;
    let parsed: Value = serde_json::from_str(reply.trim()).map_err(|_| "the Bitwarden helper answered nonsense".to_string())?;
    let result = if parsed.get("ok").and_then(Value::as_bool) == Some(true) {
        println!("{}", reply.trim());
        Ok(())
    } else {
        Err(parsed.get("error").and_then(Value::as_str).unwrap_or("it failed").to_string())
    };
    unsafe { reply.as_bytes_mut().fill(0) };
    result
}

/// A line from stdin, for a secret that mustn't be on the command line
fn read_secret() -> Result<Secret, String> {
    let mut line = String::new();
    std::io::stdin().read_line(&mut line).map_err(|error| error.to_string())?;
    let secret = Secret(line.trim_end_matches('\n').to_string());
    unsafe { line.as_bytes_mut().fill(0) };
    Ok(secret)
}

pub fn run(args: &[String]) -> Result<(), String> {
    let arg = |index: usize| args.get(index).cloned().unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some("unlock") => request(json!({ "verb": "unlock", "password": read_secret()?.0 })),
        Some("unlock-pin") => request(json!({ "verb": "unlock-pin", "pin": read_secret()?.0 })),
        Some("pin") => request(json!({ "verb": "pin", "pin": read_secret().map(|pin| pin.0.clone()).unwrap_or_default() })),
        Some("save") => {
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).map_err(|error| error.to_string())?;
            let fields: Value = serde_json::from_str(&input).map_err(|_| "save takes the item's fields as JSON on stdin".to_string())?;
            unsafe { input.as_bytes_mut().fill(0) };
            request(json!({ "verb": "save", "fields": fields }))
        }
        // A screen lock with nothing running has nothing to lock
        Some("lock-for-screen") if UnixStream::connect(socket_path()).is_err() => Ok(()),
        Some(verb @ ("status" | "unlock-keyring" | "lock" | "lock-for-screen" | "sync" | "items" | "folders")) => request(json!({ "verb": verb })),
        Some("item") => request(json!({ "verb": "item", "id": arg(1) })),
        Some("delete") => request(json!({ "verb": "delete", "id": arg(1) })),
        Some("copy") => request(json!({ "verb": "copy", "id": arg(1), "field": arg(2) })),
        Some("open") => request(json!({ "verb": "open", "id": arg(1) })),
        Some("generate") => request(json!({ "verb": "generate", "length": arg(1).parse::<u64>().unwrap_or(20) })),
        Some("set") => {
            let raw = arg(2);
            let value = serde_json::from_str::<Value>(&raw).unwrap_or(Value::String(raw));
            request(json!({ "verb": "set", "name": arg(1), "value": value }))
        }
        _ => Err("usage: neko-core bitwarden <status|unlock|unlock-pin|unlock-keyring|lock|sync|items|folders|item <id>|save|delete <id>|generate [length]|copy <id> <field>|open <id>|set <name> <value>|pin|lock-for-screen>".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 6238's test key, "12345678901234567890", in base32
    const KEY: &str = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

    #[test]
    fn rfc_6238_codes() {
        // Its SHA-1 vector at T = 59 s, 8 digits: 94287082
        assert_eq!(totp_code(&format!("otpauth://totp/x?secret={KEY}&digits=8"), 59).as_deref(), Some("94287082"));
        // And at 1111111109 s: 07081804
        assert_eq!(totp_code(&format!("otpauth://totp/x?secret={KEY}&digits=8"), 1111111109).as_deref(), Some("07081804"));
        // A bare secret: six digits, the last six of the same code
        assert_eq!(totp_code(KEY, 59).as_deref(), Some("287082"));
        // Lower case and spaces read the same
        assert_eq!(totp_code("gezd gnbv gy3t qojq gezd gnbv gy3t qojq", 59).as_deref(), Some("287082"));
    }

    #[test]
    fn rfc_6238_sha256() {
        // Its SHA-256 key is 32 bytes: "12345678901234567890123456789012"
        let key = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA";
        assert_eq!(totp_code(&format!("otpauth://totp/x?secret={key}&digits=8&algorithm=SHA256"), 59).as_deref(), Some("46119246"));
    }

    #[test]
    fn what_it_cannot_make() {
        assert_eq!(totp_code("steam://ABCDEF", 59), None);
        assert_eq!(totp_code("not base32 !!", 59), None);
    }

    #[test]
    fn pbkdf2_vector() {
        // RFC 7914 §11's PBKDF2-HMAC-SHA256 vector, first block: "passwd",
        // "salt", one round
        assert_eq!(hex::encode(pbkdf2(b"passwd", b"salt", 1)), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc");
    }

    #[test]
    fn passwords_generated() {
        let password = generate(24, true, true);
        assert_eq!(password.chars().count(), 24);
        let plain = generate(16, false, false);
        assert!(plain.chars().all(|c| c.is_ascii_alphabetic()));
        assert_ne!(generate(20, true, true), generate(20, true, true));
    }

    #[test]
    fn fields_onto_a_new_login() {
        let item = apply_fields(None, &json!({ "type": 1, "name": "Mail", "username": "me", "password": "pw", "uri": "mail.example.com" }));
        assert_eq!(item["name"], "Mail");
        assert_eq!(item["login"]["username"], "me");
        assert_eq!(item["login"]["password"], "pw");
        assert_eq!(item["login"]["uris"][0]["uri"], "mail.example.com");
        // An edit keeps what it doesn't change
        let edited = apply_fields(Some(&item), &json!({ "password": "new" }));
        assert_eq!(edited["login"]["username"], "me");
        assert_eq!(edited["login"]["password"], "new");
        // Emptied, a field goes to null rather than ""
        let cleared = apply_fields(Some(&item), &json!({ "username": "" }));
        assert!(cleared["login"]["username"].is_null());
    }

    #[test]
    fn a_note_has_no_login() {
        let note = apply_fields(None, &json!({ "type": 2, "name": "Wi-Fi", "notes": "hunter2" }));
        assert!(note["login"].is_null());
        assert_eq!(note["secureNote"]["type"], 0);
        assert_eq!(note["notes"], "hunter2");
    }
}
