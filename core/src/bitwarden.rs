//! `neko-core bitwarden`: the Bitwarden vault for the bar's panel, through the
//! official `bw` CLI.
//!
//! `bw` takes seconds a call (it's a Node program), so it runs only to unlock
//! and to sync. One process holds what that gave: `serve`, run as its own
//! user unit (neko-bitwarden), listening on $XDG_RUNTIME_DIR/neko/bitwarden.sock,
//! which only this user can reach. It keeps the session key, the vault's list
//! without a secret in it (names, usernames, sites, whether there's a code)
//! for the panel to search, and each item's password and 2FA secret apart,
//! for copying at once; codes are generated here (RFC 6238). All of it is
//! wiped on lock, after 15 idle minutes, or when the process ends. The key
//! reaches `bw` through its environment, never a command line (anyone's `ps`
//! shows those).
//!
//! Copies are marked sensitive, so clipboard history leaves them out, and
//! cleared after 30 seconds if they're still there.
//!
//! With "remember" on, the master password is kept in the login keyring
//! (Secret Service, through secret-tool) after an unlock, for a quicker one
//! later; the panel asks for a face first (Howdy, through PAM) and then for
//! `unlock-keyring`.
//!
//!   status                 locked, unlocked or logged out, and the account
//!   unlock                 with the master password on stdin
//!   unlock-keyring         with the password the keyring kept
//!   lock | sync | items
//!   copy <id> <field>      username, password, totp or uri
//!   open <id>              the item's first site, in the browser
//!   remember <on|off>      keep the master password in the keyring, or not
//!   serve                  the holder (neko-bitwarden.service)

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::{self, sleep};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha512};

const UNIT: &str = "neko-bitwarden";
const KEYRING_SERVICE: &str = "neko-bitwarden";
const AUTOLOCK: Duration = Duration::from_secs(15 * 60);
const CLEAR_AFTER: Duration = Duration::from_secs(30);

/// A string wiped from memory when dropped
struct Secret(String);

impl Drop for Secret {
    fn drop(&mut self) {
        // Safety: zeroes keep the bytes valid UTF-8
        unsafe { self.0.as_bytes_mut().fill(0) };
    }
}

fn wipe(bytes: &mut Vec<u8>) {
    bytes.fill(0);
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

fn remembering() -> bool {
    fs::read_to_string(settings_path())
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|settings| settings.get("remember").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn set_remembering(on: bool) {
    let path = settings_path();
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(path, json!({ "remember": on }).to_string());
}

// ------------------------------------------------------------------ bw

/// Runs `bw` with the session key in its environment; its output, or what it
/// said went wrong
fn bw(args: &[&str], session: Option<&Secret>, extra_env: Option<(&str, &Secret)>) -> Result<Vec<u8>, String> {
    let mut command = Command::new("bw");
    command.args(args).env("BW_NOINTERACTION", "true").stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(key) = session {
        command.env("BW_SESSION", &key.0);
    }
    if let Some((name, value)) = extra_env {
        command.env(name, &value.0);
    }
    let output = command.output().map_err(|error| format!("can't run bw: {error}"))?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let said = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let mut stdout = output.stdout;
    wipe(&mut stdout);
    Err(if said.is_empty() { format!("bw {} failed", args.first().unwrap_or(&"")) } else { said })
}

/// An item's secrets, kept apart from the list the panel sees
struct Secrets {
    password: Option<Secret>,
    totp: Option<Secret>,
}

fn take_secret(value: Option<&Value>) -> Option<Secret> {
    value.and_then(Value::as_str).filter(|text| !text.is_empty()).map(|text| Secret(text.to_string()))
}

/// The vault's items without a secret in them, and their secrets by id
fn list_items(session: &Secret) -> Result<(Vec<Value>, HashMap<String, Secrets>), String> {
    let mut raw = bw(&["list", "items"], Some(session), None)?;
    let parsed: Result<Value, _> = serde_json::from_slice(&raw);
    wipe(&mut raw);
    let mut items = parsed.map_err(|error| format!("can't read bw's list: {error}"))?;
    let mut secrets = HashMap::new();
    for item in items.as_array().into_iter().flatten() {
        let Some(id) = item.get("id").and_then(Value::as_str) else { continue };
        let login = item.get("login");
        secrets.insert(
            id.to_string(),
            Secrets {
                password: take_secret(login.and_then(|login| login.get("password"))),
                totp: take_secret(login.and_then(|login| login.get("totp"))),
            },
        );
    }
    let list = items
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|item| {
                    let login = item.get("login");
                    let uri = login
                        .and_then(|login| login.get("uris"))
                        .and_then(Value::as_array)
                        .and_then(|uris| uris.first())
                        .and_then(|uri| uri.get("uri"))
                        .cloned()
                        .unwrap_or(Value::Null);
                    json!({
                        "id": item.get("id"),
                        "name": item.get("name"),
                        // 1 login, 2 note, 3 card, 4 identity, 5 SSH key
                        "type": item.get("type"),
                        "favorite": item.get("favorite").and_then(Value::as_bool).unwrap_or(false),
                        "folderId": item.get("folderId"),
                        "username": login.and_then(|login| login.get("username")).cloned().unwrap_or(Value::Null),
                        "uri": uri,
                        "hasPassword": login.and_then(|login| login.get("password")).is_some_and(|password| !password.is_null()),
                        "hasTotp": login.and_then(|login| login.get("totp")).is_some_and(|totp| !totp.is_null()),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    // The parsed copy held every secret: blank them before it goes
    blank_strings(&mut items);
    Ok((list, secrets))
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

fn hmac(key: &[u8], message: &[u8], block: usize, hash: fn(&[u8]) -> Vec<u8>) -> Vec<u8> {
    let mut key = if key.len() > block { hash(key) } else { key.to_vec() };
    key.resize(block, 0);
    let inner: Vec<u8> = key.iter().map(|byte| byte ^ 0x36).chain(message.iter().copied()).collect();
    let outer: Vec<u8> = key.iter().map(|byte| byte ^ 0x5c).chain(hash(&inner)).collect();
    hash(&outer)
}

/// The code a 2FA secret gives now: a bare base32 secret (SHA-1, 6 digits,
/// 30 seconds), or an otpauth:// URI naming its own. None for what it can't
/// make (Steam's codes), which `bw` then makes instead.
fn totp_code(entry: &str, now_s: u64) -> Option<String> {
    let (secret, mut algorithm, mut digits, mut period) = (entry.to_string(), "SHA1".to_string(), 6u32, 30u64);
    let mut secret = secret;
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
        "SHA256" => hmac(&key, &counter, 64, |data| Sha256::digest(data).to_vec()),
        "SHA512" => hmac(&key, &counter, 128, |data| Sha512::digest(data).to_vec()),
        _ => return None,
    };
    let offset = (mac.last()? & 0x0f) as usize;
    let number = u32::from_be_bytes([mac[offset] & 0x7f, mac[offset + 1], mac[offset + 2], mac[offset + 3]]);
    Some(format!("{:0width$}", number % 10u32.pow(digits), width = digits as usize))
}

// ------------------------------------------------------------- clipboard

/// Copies, marked sensitive, and clears it after a while if it's unchanged
fn copy_sensitive(value: Secret) -> Result<(), String> {
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
    thread::spawn(move || {
        sleep(CLEAR_AFTER);
        let still = Command::new("wl-paste").arg("--no-newline").stderr(Stdio::null()).output();
        if let Ok(mut output) = still {
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
        return Err("the keyring has no password kept for this account".into());
    }
    String::from_utf8(output.stdout).map(|text| Secret(text.trim_end_matches('\n').to_string())).map_err(|_| "the kept password isn't text".into())
}

fn keyring_clear(account: &str) {
    let _ = Command::new("secret-tool").args(["clear", "service", KEYRING_SERVICE, "account", account]).status();
}

// ---------------------------------------------------------------- server

struct Vault {
    session: Option<Secret>,
    items: Vec<Value>,
    secrets: HashMap<String, Secrets>,
    /// The account's email, or empty when logged out
    account: String,
    logged_in: bool,
    last_used: Instant,
}

impl Vault {
    fn read_status(&mut self) {
        if let Ok(mut raw) = bw(&["status"], self.session.as_ref(), None) {
            if let Ok(status) = serde_json::from_slice::<Value>(&raw) {
                self.account = status.get("userEmail").and_then(Value::as_str).unwrap_or("").to_string();
                self.logged_in = status.get("status").and_then(Value::as_str) != Some("unauthenticated");
            }
            wipe(&mut raw);
        }
    }

    fn status(&self) -> Value {
        json!({
            "ok": true,
            "state": if !self.logged_in { "logged-out" } else if self.session.is_some() { "unlocked" } else { "locked" },
            "account": self.account,
            "count": self.items.len(),
            "remember": remembering(),
        })
    }

    fn lock(&mut self) {
        if let Some(session) = self.session.take() {
            let _ = bw(&["lock"], Some(&session), None);
        }
        self.items.clear();
        self.secrets.clear();
    }

    fn unlock(&mut self, password: Secret) -> Result<Value, String> {
        let mut raw = bw(&["unlock", "--raw", "--passwordenv", "NEKO_BW_PASSWORD"], None, Some(("NEKO_BW_PASSWORD", &password)))?;
        let key = Secret(String::from_utf8_lossy(&raw).trim().to_string());
        wipe(&mut raw);
        if key.0.is_empty() {
            return Err("bw gave no session key".into());
        }
        (self.items, self.secrets) = list_items(&key)?;
        self.session = Some(key);
        if remembering() && !self.account.is_empty() {
            keyring_store(&self.account, &password)?;
        }
        Ok(self.status())
    }

    fn handle(&mut self, request: &Value) -> Result<Value, String> {
        let verb = request.get("verb").and_then(Value::as_str).unwrap_or("");
        if verb != "status" {
            self.last_used = Instant::now();
        }
        match verb {
            "status" => Ok(self.status()),
            "unlock" => {
                let password = Secret(request.get("password").and_then(Value::as_str).unwrap_or("").to_string());
                if password.0.is_empty() {
                    return Err("no password given".into());
                }
                self.unlock(password)
            }
            "unlock-keyring" => {
                let password = keyring_lookup(&self.account)?;
                self.unlock(password)
            }
            "lock" => {
                self.lock();
                Ok(self.status())
            }
            "sync" => {
                let session = self.session.as_ref().ok_or("the vault is locked")?;
                bw(&["sync"], Some(session), None)?;
                (self.items, self.secrets) = list_items(session)?;
                Ok(self.status())
            }
            "items" => {
                if self.session.is_none() {
                    return Err("the vault is locked".into());
                }
                Ok(json!({ "ok": true, "items": self.items }))
            }
            "copy" => {
                let id = request.get("id").and_then(Value::as_str).unwrap_or("");
                let field = request.get("field").and_then(Value::as_str).unwrap_or("");
                let session = self.session.as_ref().ok_or("the vault is locked")?;
                let item = self.items.iter().find(|item| item.get("id").and_then(Value::as_str) == Some(id)).ok_or("no such item")?;
                let kept = self.secrets.get(id);
                let value = match field {
                    "username" | "uri" => Secret(item.get(field).and_then(Value::as_str).unwrap_or("").to_string()),
                    "password" => Secret(kept.and_then(|secrets| secrets.password.as_ref()).map(|password| password.0.clone()).unwrap_or_default()),
                    "totp" => {
                        let entry = kept.and_then(|secrets| secrets.totp.as_ref()).ok_or("this item has no 2FA code")?;
                        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_secs()).unwrap_or(0);
                        match totp_code(&entry.0, now) {
                            Some(code) => Secret(code),
                            // One it can't make here: bw makes it
                            None => {
                                let mut raw = bw(&["get", "totp", id], Some(session), None)?;
                                let code = Secret(String::from_utf8_lossy(&raw).trim().to_string());
                                wipe(&mut raw);
                                code
                            }
                        }
                    }
                    _ => return Err(format!("can't copy {field}")),
                };
                if value.0.is_empty() {
                    return Err(format!("this item has no {field}"));
                }
                copy_sensitive(value)?;
                Ok(json!({ "ok": true, "clearsIn": CLEAR_AFTER.as_secs() }))
            }
            "open" => {
                let id = request.get("id").and_then(Value::as_str).unwrap_or("");
                let item = self.items.iter().find(|item| item.get("id").and_then(Value::as_str) == Some(id)).ok_or("no such item")?;
                let uri = item.get("uri").and_then(Value::as_str).ok_or("this item has no site")?;
                let uri = if uri.contains("://") { uri.to_string() } else { format!("https://{uri}") };
                Command::new("xdg-open").arg(uri).spawn().map_err(|error| format!("can't open it: {error}"))?;
                Ok(json!({ "ok": true }))
            }
            "remember" => {
                let on = request.get("on").and_then(Value::as_bool).unwrap_or(false);
                set_remembering(on);
                if !on && !self.account.is_empty() {
                    keyring_clear(&self.account);
                }
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

    let mut vault = Vault {
        session: None,
        items: Vec::new(),
        secrets: HashMap::new(),
        account: String::new(),
        logged_in: false,
        last_used: Instant::now(),
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
                        Ok(request) => vault.handle(&request).unwrap_or_else(|error| json!({ "ok": false, "error": error })),
                        Err(_) => json!({ "ok": false, "error": "not a request" }),
                    },
                    Err(error) => json!({ "ok": false, "error": error.to_string() }),
                };
                // The request may have carried the master password
                unsafe { line.as_bytes_mut().fill(0) };
                let mut stream = stream;
                let _ = writeln!(stream, "{reply}");
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                sleep(Duration::from_millis(100));
                if vault.session.is_some() && vault.last_used.elapsed() > AUTOLOCK {
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
    for name in ["PATH", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "BITWARDENCLI_APPDATA_DIR"] {
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
    writeln!(stream, "{body}").map_err(|error| error.to_string())?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply).map_err(|error| error.to_string())?;
    let parsed: Value = serde_json::from_str(reply.trim()).map_err(|_| "the Bitwarden helper answered nonsense".to_string())?;
    if parsed.get("ok").and_then(Value::as_bool) == Some(true) {
        println!("{}", reply.trim());
        Ok(())
    } else {
        Err(parsed.get("error").and_then(Value::as_str).unwrap_or("it failed").to_string())
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    let arg = |index: usize| args.get(index).cloned().unwrap_or_default();
    match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some("unlock") => {
            let mut password = String::new();
            std::io::stdin().read_line(&mut password).map_err(|error| error.to_string())?;
            let secret = Secret(password.trim_end_matches('\n').to_string());
            unsafe { password.as_bytes_mut().fill(0) };
            request(json!({ "verb": "unlock", "password": secret.0 }))
        }
        Some(verb @ ("status" | "unlock-keyring" | "lock" | "sync" | "items")) => request(json!({ "verb": verb })),
        Some("copy") => request(json!({ "verb": "copy", "id": arg(1), "field": arg(2) })),
        Some("open") => request(json!({ "verb": "open", "id": arg(1) })),
        Some("remember") => request(json!({ "verb": "remember", "on": arg(1) == "on" })),
        _ => Err("usage: neko-core bitwarden <status|unlock|unlock-keyring|lock|sync|items|copy <id> <field>|open <id>|remember <on|off>>".into()),
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
}
