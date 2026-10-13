//! `neko-core faceauth-watch`: a line each time Howdy looks for a face, and
//! how it went, for the bar's island.
//!
//! Howdy logs only its verdict, not that it has started looking, but it opens
//! its IR camera when it starts and closes it when done. This waits on those
//! opens and closes through inotify, asleep in the kernel in between (nothing
//! polls), and prints:
//!
//!   scanning   the camera has been open a moment (a quick probe doesn't count)
//!   approved   Howdy let the face in
//!   failed     it gave up (timeout, or no match)
//!   done       the camera closed with no verdict to read
//!
//! The verdict is read from the journal once per scan. Without Howdy, or with
//! a camera it can't watch, it says so and exits.

use std::ffi::CString;
use std::fs;
use std::io::Write;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CONFIG: &str = "/etc/howdy/config.ini";
/// An open shorter than this is a probe (PipeWire looking at devices), not a scan
const SETTLE_MS: i32 = 150;

/// video.device_path from Howdy's config, resolved
fn camera_path() -> Result<String, String> {
    let text = fs::read_to_string(CONFIG).map_err(|_| format!("Howdy isn't set up ({CONFIG} is missing)"))?;
    let mut in_video = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_video = line.eq_ignore_ascii_case("[video]");
            continue;
        }
        if !in_video || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            if key.trim() == "device_path" {
                let value = value.trim();
                if value.is_empty() {
                    break;
                }
                return fs::canonicalize(value)
                    .map(|path| path.to_string_lossy().into_owned())
                    .map_err(|error| format!("can't find the camera {value}: {error}"));
            }
        }
    }
    Err(format!("{CONFIG} names no camera (video.device_path)"))
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
}

/// Howdy's last word since the scan began, waiting a moment for it to land
fn verdict(since: f64) -> &'static str {
    for _ in 0..6 {
        let output = Command::new("journalctl")
            .args(["-q", "-t", "pam_howdy", "-o", "cat", "--since", &format!("@{since:.0}")])
            .output();
        if let Ok(output) = output {
            for line in String::from_utf8_lossy(&output.stdout).lines().rev() {
                let line = line.to_lowercase();
                if line.contains("approved") {
                    return "approved";
                }
                if line.contains("failure") || line.contains("timeout") {
                    return "failed";
                }
            }
        }
        sleep(Duration::from_millis(200));
    }
    "done"
}

/// Whether more events arrive within `ms`
fn events_within(fd: i32, ms: i32) -> bool {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    unsafe { libc::poll(&mut poll, 1, ms) > 0 }
}

/// Reads what's waiting and moves the count of open handles on the camera
fn read_events(fd: i32, opened: &mut i32) -> Result<(), String> {
    let mut buffer = [0u8; 4096];
    let length = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    if length < 0 {
        return Err(format!("reading inotify: {}", std::io::Error::last_os_error()));
    }
    let header = std::mem::size_of::<libc::inotify_event>();
    let mut offset = 0;
    while offset + header <= length as usize {
        // Events are packed back to back, each followed by its name
        let event: libc::inotify_event = unsafe { std::ptr::read_unaligned(buffer.as_ptr().add(offset).cast()) };
        offset += header + event.len as usize;
        if event.mask & libc::IN_OPEN != 0 {
            *opened += 1;
        } else if event.mask & (libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE) != 0 {
            *opened = (*opened - 1).max(0);
        }
    }
    Ok(())
}

/// A line to the island; a closed pipe means the shell has gone, so stop
fn say(line: &str) -> Result<(), String> {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}").and_then(|()| stdout.flush()).map_err(|_| String::new())
}

pub fn run(args: &[String]) -> Result<(), String> {
    if let Some(arg) = args.first() {
        if arg == "-h" || arg == "--help" {
            println!("Usage: neko-faceauth-watch (prints scanning, then approved, failed or done)");
            return Ok(());
        }
        return Err(format!("unknown argument: {arg}"));
    }
    let path = camera_path()?;
    let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
    if fd < 0 {
        return Err("can't start inotify".into());
    }
    let c_path = CString::new(path.clone()).map_err(|_| "bad camera path".to_string())?;
    let mask = libc::IN_OPEN | libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE;
    if unsafe { libc::inotify_add_watch(fd, c_path.as_ptr(), mask) } < 0 {
        return Err(format!("can't watch {path}: {}", std::io::Error::last_os_error()));
    }

    let mut opened = 0;
    let mut scanning = false;
    let mut started = 0.0;
    loop {
        read_events(fd, &mut opened)?;
        if opened > 0 && !scanning {
            // Open long enough to be Howdy looking, not a probe
            if events_within(fd, SETTLE_MS) {
                continue;
            }
            scanning = true;
            started = now_secs() - f64::from(SETTLE_MS) / 1000.0;
            if say("scanning").is_err() {
                return Ok(());
            }
        } else if opened == 0 && scanning {
            // OpenCV can close and reopen the camera as it starts; a scan is
            // over once it stays closed
            if events_within(fd, SETTLE_MS) {
                continue;
            }
            scanning = false;
            if say(verdict(started - 1.0)).is_err() {
                return Ok(());
            }
        }
    }
}
