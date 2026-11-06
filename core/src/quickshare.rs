//! `neko-core quickshare`: the Quick Share widget's side of the Quick Share
//! service, a separate program (it bundles a GPL-3.0 protocol library, so it
//! isn't part of neko) that sends to and receives from Android phones. This
//! only talks to it over the session bus; files and keys never pass through
//! here.
//!
//!   status                        whether the service is there and new enough,
//!                                 and its snapshot, as JSON
//!   watch                         the same, a line each time it changes,
//!                                 carrying on when the service comes and goes
//!   visible <seconds>             let phones nearby see this one (0 hides it;
//!                                 at most 600)
//!   send <device id>              send files to a device: the paths as a JSON
//!                                 array on stdin, so no other user can read
//!                                 them off the command line
//!   qr-send                       the same, to whoever scans the QR code
//!   qr-stop <id>
//!   accept|reject|cancel <transfer id>
//!   folder <path>                 where received files go
//!   network on|off                whether the service may change the network
//!                                 (a temporary hotspot) for a transfer
//!   start                         start the installed service's user unit

use std::io::Read;
use std::sync::mpsc;
use std::thread;

use serde_json::{Value, json};
use zbus::MatchRule;
use zbus::blocking::{Connection, MessageIterator};
use zbus::message::Type;

// The service's own names, which it sets and neko can't change: its bus name,
// object, interface, program and unit. Every one of them is here.
const BUS: &str = "io.omarchy.QuickShare";
const PATH: &str = "/io/omarchy/QuickShare";
const INTERFACE: &str = "io.omarchy.QuickShare1";
const PROGRAM: &str = "omarchy-quickshare";
const UNIT: &str = "omarchy-quickshare.service";
/// Older services lack security fixes the protocol needs
const MINIMUM: (u64, u64, u64) = (0, 3, 7);
const MAX_FILES: usize = 1000;

fn version(text: &str) -> Option<(u64, u64, u64)> {
    // A prerelease isn't a release that has the fixes
    if text.contains('-') {
        return None;
    }
    let mut parts = text.trim().split('.').map(|part| part.parse::<u64>().ok());
    Some((parts.next()??, parts.next()??, parts.next()??))
}

fn minimum_text() -> String {
    format!("{}.{}.{}", MINIMUM.0, MINIMUM.1, MINIMUM.2)
}

/// Where a copy of the service is installed, if one is
fn installed() -> bool {
    let home = std::env::var("HOME").unwrap_or_default();
    [format!("/usr/bin/{PROGRAM}"), format!("{home}/.local/bin/{PROGRAM}")]
        .iter()
        .any(|path| std::path::Path::new(path).is_file())
}

/// The snapshot, judged: ready, too old, or not running
fn judged(snapshot: Option<&str>) -> Value {
    let Some(text) = snapshot else {
        return json!({ "state": if installed() { "stopped" } else { "missing" }, "minimum": minimum_text() });
    };
    let Ok(snapshot) = serde_json::from_str::<Value>(text) else {
        return json!({ "state": "old", "minimum": minimum_text() });
    };
    let backend = snapshot["backend_version"].as_str().unwrap_or_default();
    let new_enough = snapshot["version"].as_u64() == Some(1) && version(backend).is_some_and(|found| found >= MINIMUM);
    if new_enough {
        json!({ "state": "ready", "snapshot": snapshot })
    } else {
        json!({ "state": "old", "version": backend, "minimum": minimum_text() })
    }
}

fn call<B: zbus::export::serde::Serialize + zbus::zvariant::DynamicType>(connection: &Connection, method: &str, body: &B) -> Result<zbus::message::Message, String> {
    connection
        .call_method(Some(BUS), PATH, Some(INTERFACE), method, body)
        .map_err(|error| match error {
            zbus::Error::MethodError(_, Some(detail), _) => detail,
            zbus::Error::MethodError(name, None, _) if name.as_str().ends_with("ServiceUnknown") => "the Quick Share service isn't running".into(),
            other => other.to_string(),
        })
}

/// The unique bus name that holds the service's name now
fn owner(connection: &Connection) -> Option<String> {
    connection
        .call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"), "GetNameOwner", &(BUS,))
        .ok()?
        .body()
        .deserialize::<String>()
        .ok()
}

fn snapshot(connection: &Connection) -> Option<String> {
    call(connection, "Snapshot", &()).ok()?.body().deserialize::<String>().ok()
}

/// What the service can be asked once it's checked as new enough: a service
/// too old is refused before anything is sent to it
fn ready(connection: &Connection) -> Result<(), String> {
    match judged(snapshot(connection).as_deref())["state"].as_str() {
        Some("ready") => Ok(()),
        Some("old") => Err(format!("the Quick Share service is older than {}; update it", minimum_text())),
        _ => Err("the Quick Share service isn't running".into()),
    }
}

fn print(value: &Value) {
    println!("{value}");
}

/// Paths as a JSON array on stdin, made absolute
fn files_from_stdin() -> Result<Vec<String>, String> {
    let mut text = String::new();
    std::io::stdin().take(32 * 1024 * 1024).read_to_string(&mut text).map_err(|error| format!("can't read the files: {error}"))?;
    let files: Vec<String> = serde_json::from_str(&text).map_err(|_| "the files go on stdin, as a JSON array of paths")?;
    if files.is_empty() || files.len() > MAX_FILES {
        return Err(format!("send between 1 and {MAX_FILES} files"));
    }
    let here = std::env::current_dir().map_err(|error| error.to_string())?;
    Ok(files
        .into_iter()
        .map(|file| if file.starts_with('/') { file } else { here.join(file).display().to_string() })
        .collect())
}

/// A line each time the service's snapshot changes, and one when it comes or
/// goes. Stale revisions (an older signal arriving late) are dropped.
fn watch() -> Result<(), String> {
    let connection = Connection::session().map_err(|error| format!("can't reach the session bus: {error}"))?;
    let (tell, heard) = mpsc::channel::<Option<String>>();

    let changes = MatchRule::builder()
        .msg_type(Type::Signal)
        .interface(INTERFACE)
        .and_then(|rule| rule.member("Changed"))
        .and_then(|rule| rule.path(PATH))
        .map_err(|error| error.to_string())?
        .build();
    let owners = MatchRule::builder()
        .msg_type(Type::Signal)
        .sender("org.freedesktop.DBus")
        .and_then(|rule| rule.interface("org.freedesktop.DBus"))
        .and_then(|rule| rule.member("NameOwnerChanged"))
        .and_then(|rule| rule.arg(0, BUS))
        .map_err(|error| error.to_string())?
        .build();
    // Listening before the first snapshot, so a change between can't be missed
    let changed = MessageIterator::for_match_rule(changes, &connection, None).map_err(|error| error.to_string())?;
    let owned = MessageIterator::for_match_rule(owners, &connection, None).map_err(|error| error.to_string())?;

    // Any program on the bus can send a Changed signal: only the one from
    // whoever owns the service's name now counts
    let signals = tell.clone();
    let signal_connection = connection.clone();
    thread::spawn(move || {
        for message in changed.flatten() {
            let sender = message.header().sender().map(|name| name.to_string());
            if sender.is_none() || sender != owner(&signal_connection) {
                continue;
            }
            if let Ok(text) = message.body().deserialize::<String>() {
                let _ = signals.send(Some(text));
            }
        }
    });
    let owner_connection = connection.clone();
    thread::spawn(move || {
        for message in owned.flatten() {
            let Ok((_, _, new_owner)) = message.body().deserialize::<(String, String, String)>() else { continue };
            // Gone: say so; back: its first snapshot
            let _ = tell.send(if new_owner.is_empty() { None } else { snapshot(&owner_connection) });
        }
    });

    let mut current = (String::new(), 0_u64);
    let mut show = |text: Option<String>| {
        if let Some(text) = &text {
            if let Ok(parsed) = serde_json::from_str::<Value>(text) {
                let instance = parsed["instance_id"].as_str().unwrap_or_default().to_string();
                let revision = parsed["revision"].as_u64().unwrap_or(0);
                if instance == current.0 && revision <= current.1 && revision > 0 {
                    return;
                }
                current = (instance, revision);
            }
        } else {
            current = (String::new(), 0);
        }
        print(&judged(text.as_deref()));
    };
    show(snapshot(&connection));
    for text in heard {
        show(text);
    }
    Ok(())
}

pub fn run(args: &[String]) -> Result<(), String> {
    let Some((verb, rest)) = args.split_first() else {
        return Err("usage: neko-core quickshare <status|watch|start|visible|send|qr-send|qr-stop|accept|reject|cancel|folder|network>".into());
    };
    if verb == "watch" {
        return watch();
    }
    if verb == "start" {
        let started = std::process::Command::new("systemctl")
            .args(["--user", "start", UNIT])
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|error| format!("can't run systemctl: {error}"))?;
        return if started.success() { Ok(()) } else { Err("the Quick Share service didn't start".into()) };
    }
    let connection = Connection::session().map_err(|error| format!("can't reach the session bus: {error}"))?;
    if verb == "status" {
        print(&judged(snapshot(&connection).as_deref()));
        return Ok(());
    }
    ready(&connection)?;
    let id = || rest.first().cloned().ok_or_else(|| format!("{verb} needs an id"));
    match verb.as_str() {
        "visible" => {
            let seconds: u32 = rest.first().and_then(|text| text.parse().ok()).filter(|seconds| *seconds <= 600).ok_or("visible takes 0 to 600 seconds")?;
            call(&connection, "SetVisibility", &(seconds,)).map(|_| ())
        }
        "send" => {
            let peer = id()?;
            let files = files_from_stdin()?;
            let reply = call(&connection, "Send", &(peer, files))?;
            print(&json!({ "transfer": reply.body().deserialize::<String>().unwrap_or_default() }));
            Ok(())
        }
        "qr-send" => {
            let files = files_from_stdin()?;
            let reply = call(&connection, "StartQrSend", &(files,))?;
            print(&json!({ "invitation": reply.body().deserialize::<String>().unwrap_or_default() }));
            Ok(())
        }
        "qr-stop" => call(&connection, "StopQrSend", &(id()?,)).map(|_| ()),
        "accept" => call(&connection, "Respond", &(id()?, true)).map(|_| ()),
        "reject" => call(&connection, "Respond", &(id()?, false)).map(|_| ()),
        "cancel" => call(&connection, "Cancel", &(id()?,)).map(|_| ()),
        "folder" => {
            let folder = rest.first().ok_or("folder needs a path")?;
            if !folder.starts_with('/') {
                return Err("the folder needs a full path".into());
            }
            call(&connection, "SetDownloadDirectory", &(folder.clone(),)).map(|_| ())
        }
        "network" => {
            let allowed = match rest.first().map(String::as_str) {
                Some("on") => true,
                Some("off") => false,
                _ => return Err("network takes on or off".into()),
            };
            call(&connection, "SetNetworkConsent", &(allowed,)).map(|_| ())
        }
        other => Err(format!("unknown quickshare command: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_versions() {
        assert_eq!(version("0.3.7"), Some((0, 3, 7)));
        assert_eq!(version("0.4.0-alpha"), None);
        assert_eq!(version("1.2"), None);
    }

    #[test]
    fn judges_the_service() {
        let ready = judged(Some(r#"{"version":1,"backend_version":"0.3.8","devices":[]}"#));
        assert_eq!(ready["state"], "ready");
        assert_eq!(judged(Some(r#"{"version":1,"backend_version":"0.3.6"}"#))["state"], "old");
        assert_eq!(judged(Some(r#"{"version":2,"backend_version":"0.9.0"}"#))["state"], "old");
        assert_eq!(judged(Some("not json"))["state"], "old");
    }
}
