//! `neko-core file-select`: pick files with the desktop's file chooser (the
//! xdg-desktop-portal FileChooser), printing each path on its own line.
//!
//! The portal answers with a Response signal addressed to the connection that
//! asked, so the call and the wait share one connection; no shell D-Bus tool
//! can hold one across both.
//!
//! Exit codes: 0 picked, 1 nothing picked (cancelled, or no answer in ten
//! minutes), 2 the chooser didn't run. Callers act on the difference.

use std::collections::HashMap;
use std::process::exit;
use std::thread;
use std::time::Duration;

use zbus::blocking::{Connection, MessageIterator};
use zbus::message::Type;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
use zbus::MatchRule;

const DESKTOP: &str = "org.freedesktop.portal.Desktop";
/// A dialog nobody ever answers would otherwise keep this, and whatever waits
/// on its output, alive forever
const ANSWER_TIMEOUT: Duration = Duration::from_secs(600);

const EXIT_NOTHING_PICKED: i32 = 1;
const EXIT_CHOOSER_FAILED: i32 = 2;

struct Options {
    title: String,
    multiple: bool,
    directory: bool,
    extensions: Vec<String>,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut options = Options { title: "Select file".into(), multiple: false, directory: false, extensions: vec![] };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--title" => options.title = it.next().ok_or("--title needs a title")?.clone(),
            "--multiple" => options.multiple = true,
            "--directory" => options.directory = true,
            "--extensions" => {
                options.extensions = it
                    .next()
                    .ok_or("--extensions needs a list")?
                    .split_whitespace()
                    .map(|ext| ext.trim_start_matches('.').to_lowercase())
                    .collect()
            }
            other => return Err(format!("unknown option {other}")),
        }
    }
    Ok(options)
}

fn responses(conn: &Connection, path: &str) -> zbus::Result<MessageIterator> {
    let rule = MatchRule::builder()
        .msg_type(Type::Signal)
        .interface("org.freedesktop.portal.Request")?
        .member("Response")?
        .path(path.to_string())?
        .build();
    MessageIterator::for_match_rule(rule, conn, None)
}

/// A file:// URI's path, percent-decoded
fn path_from_uri(uri: &str) -> String {
    let encoded = uri.strip_prefix("file://").unwrap_or(uri);
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&encoded[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn pick(options: &Options) -> zbus::Result<Vec<String>> {
    let conn = Connection::session()?;
    // The request's path follows from our bus name and the token we pass, so
    // it can be listened on before asking: asking first would race a dialog
    // answered at once
    let token = format!("neko{}", std::process::id());
    let sender = conn.unique_name().map(|name| name.trim_start_matches(':').replace('.', "_")).unwrap_or_default();
    let predicted = format!("/org/freedesktop/portal/desktop/request/{sender}/{token}");
    let mut answers = responses(&conn, &predicted)?;

    let mut call: HashMap<&str, Value> = HashMap::new();
    call.insert("handle_token", Value::from(token.as_str()));
    call.insert("multiple", Value::from(options.multiple));
    if options.directory {
        call.insert("directory", Value::from(true));
    }
    // Filters name file formats, which a directory chooser has no use for.
    // Globs in the chooser are case-sensitive, so both cases are covered.
    if !options.extensions.is_empty() && !options.directory {
        let mut patterns: Vec<(u32, String)> = options.extensions.iter().map(|ext| (0, format!("*.{ext}"))).collect();
        patterns.extend(options.extensions.iter().map(|ext| (0, format!("*.{}", ext.to_uppercase()))));
        let label = options.extensions.iter().map(|ext| format!("*.{ext}")).collect::<Vec<_>>().join(" ");
        call.insert("filters", Value::from(vec![(label.clone(), patterns.clone())]));
        call.insert("current_filter", Value::from((label, patterns)));
    }

    let reply = conn.call_method(
        Some(DESKTOP),
        "/org/freedesktop/portal/desktop",
        Some("org.freedesktop.portal.FileChooser"),
        "OpenFile",
        &("", options.title.as_str(), call),
    )?;
    let handle: OwnedObjectPath = reply.body().deserialize()?;
    // Portals predating the token convention answer on a path of their own
    if handle.as_str() != predicted {
        answers = responses(&conn, handle.as_str())?;
    }

    thread::spawn(|| {
        thread::sleep(ANSWER_TIMEOUT);
        exit(EXIT_NOTHING_PICKED);
    });

    for message in answers {
        let message = message?;
        let (code, results): (u32, HashMap<String, OwnedValue>) = message.body().deserialize()?;
        if code != 0 {
            return Ok(vec![]);
        }
        let uris = results
            .get("uris")
            .and_then(|value| Vec::<String>::try_from(value.try_clone().ok()?).ok())
            .unwrap_or_default();
        return Ok(uris.iter().map(|uri| path_from_uri(uri)).collect());
    }
    Ok(vec![])
}

pub fn run(args: &[String]) -> Result<(), String> {
    let options = match parse(args) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("neko-file-select: {error}");
            exit(EXIT_CHOOSER_FAILED);
        }
    };
    match pick(&options) {
        Ok(paths) if !paths.is_empty() => {
            for path in paths {
                println!("{path}");
            }
            Ok(())
        }
        Ok(_) => exit(EXIT_NOTHING_PICKED),
        Err(error) => {
            eprintln!("neko-file-select: {error}");
            exit(EXIT_CHOOSER_FAILED);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::path_from_uri;

    #[test]
    fn decodes_file_uris() {
        assert_eq!(path_from_uri("file:///home/me/a%20b.png"), "/home/me/a b.png");
        assert_eq!(path_from_uri("file:///tmp/caf%C3%A9.txt"), "/tmp/café.txt");
        assert_eq!(path_from_uri("file:///tmp/100%"), "/tmp/100%");
        assert_eq!(path_from_uri("file:///tmp/x%2"), "/tmp/x%2");
        assert_eq!(path_from_uri("file:///tmp/plain"), "/tmp/plain");
    }
}
