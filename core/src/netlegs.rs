//! `neko-core netlegs`: is it this network, or the internet provider? It
//! times both halves of the connection, this machine to the router and the
//! router to the internet, so the slow or broken half is plain to see.
//!
//!   run      probe, once a second, until stopped (neko-netlegs.service)
//!   start    run it as a transient user unit, if it isn't already
//!   stop     stop that unit
//!   state    what it last wrote, as JSON
//!   report   the outages it logged, as plain text for a support desk
//!
//! The router leg is an ICMP echo to the default gateway, on an unprivileged
//! ping socket (no root). The internet is a TCP handshake to port 443 of two
//! anycast resolvers, the quicker of them: a handshake can't be answered on
//! the far end's behalf, or fast-pathed the way pings are, so it times what
//! real traffic sees. Their addresses are literal, so a broken DNS server
//! can't look like an outage. The provider's leg is the internet's time less
//! the router's.
//!
//! Every second it writes $XDG_RUNTIME_DIR/neko/netlegs.json: each leg's
//! median, 95th percentile, jitter and loss over the last minute, a
//! per-minute history for the last hour, the status, and the outages, which
//! it also keeps in ~/.local/state/neko/netlegs-events.json.

use std::collections::VecDeque;
use std::fs;
use std::mem;
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::{self, sleep};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const UNIT: &str = "neko-netlegs";
const ANCHORS: [&str; 2] = ["1.1.1.1:443", "8.8.8.8:443"];
const TICK: Duration = Duration::from_secs(1);
const PING_TIMEOUT: Duration = Duration::from_millis(1000);
const CONNECT_TIMEOUT: Duration = Duration::from_millis(2000);
/// TCP's first retransmit fires at one second, so a handshake back at or past
/// this most likely lost its SYN: a lost packet, not a slow line
const RETRANSMIT_MS: f64 = 900.0;
/// The window the figures cover
const RECENT_S: i64 = 60;
/// Every answer missing for this long is an outage
const OUTAGE_S: i64 = 8;
/// Kept for the per-minute history
const HISTORY_MIN: i64 = 60;
const MAX_EVENTS: usize = 50;

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|time| time.as_millis() as i64).unwrap_or(0)
}

// ------------------------------------------------------------------ figures

/// A probe's result at a moment: a round trip in ms, or None for a loss
type Sample = (i64, Option<f64>);

/// Latency percentiles, jitter and loss over some samples. Jitter is the mean
/// difference between consecutive replies (RFC 3550's IPDV): a line that
/// alternates 10/40/10/40 ms feels far worse than one drifting over the same
/// range, and only that says so.
fn stats(samples: &[Sample]) -> Value {
    let total = samples.len();
    if total == 0 {
        return json!({ "count": 0 });
    }
    let rtts: Vec<f64> = samples.iter().filter_map(|(_, rtt)| *rtt).collect();
    let loss = (total - rtts.len()) as f64 / total as f64;
    if rtts.is_empty() {
        return json!({ "count": total, "loss": loss });
    }
    let mut ordered = rtts.clone();
    ordered.sort_by(f64::total_cmp);
    let rank = |p: f64| ordered[((p * ordered.len() as f64).ceil() as usize).clamp(1, ordered.len()) - 1];
    let median = if ordered.len() % 2 == 1 {
        ordered[ordered.len() / 2]
    } else {
        (ordered[ordered.len() / 2 - 1] + ordered[ordered.len() / 2]) / 2.0
    };
    let jitter = if rtts.len() > 1 {
        rtts.windows(2).map(|pair| (pair[1] - pair[0]).abs()).sum::<f64>() / (rtts.len() - 1) as f64
    } else {
        0.0
    };
    let round = |value: f64| (value * 10.0).round() / 10.0;
    json!({
        "count": total,
        "loss": (loss * 1000.0).round() / 1000.0,
        "p50": round(median),
        "p95": round(rank(0.95)),
        "jitter": round(jitter),
        "last": rtts.last().map(|value| round(*value)),
    })
}

/// A leg's samples, kept for the history's hour
#[derive(Default)]
struct Series(VecDeque<Sample>);

impl Series {
    fn add(&mut self, at: i64, rtt: Option<f64>) {
        self.0.push_back((at, rtt));
        while self.0.front().is_some_and(|(t, _)| *t < at - HISTORY_MIN * 60_000) {
            self.0.pop_front();
        }
    }

    fn since(&self, from: i64) -> Vec<Sample> {
        self.0.iter().filter(|(t, _)| *t >= from).copied().collect()
    }

    /// All lost, with at least a few tries, since `from`
    fn all_lost_since(&self, from: i64) -> bool {
        let recent = self.since(from);
        recent.len() >= 3 && recent.iter().all(|(_, rtt)| rtt.is_none())
    }

    /// A median and loss for each of the last hour's minutes, oldest first
    fn minutes(&self, now: i64) -> Vec<Value> {
        let this_minute = now / 60_000;
        (0..HISTORY_MIN)
            .rev()
            .map(|ago| {
                let minute = this_minute - ago;
                let samples: Vec<Sample> = self.0.iter().filter(|(t, _)| t / 60_000 == minute).copied().collect();
                let figures = stats(&samples);
                json!({
                    "t": minute * 60_000,
                    "p50": figures.get("p50").cloned().unwrap_or(Value::Null),
                    "loss": figures.get("loss").cloned().unwrap_or(Value::Null),
                })
            })
            .collect()
    }
}

// ------------------------------------------------------------------ probes

/// The default route's gateway and its interface, from the kernel's table
fn default_gateway() -> Option<(Ipv4Addr, String)> {
    let table = fs::read_to_string("/proc/net/route").ok()?;
    let mut best: Option<(u32, Ipv4Addr, String)> = None;
    for line in table.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 7 || fields[1] != "00000000" {
            continue;
        }
        let flags = u32::from_str_radix(fields[3], 16).unwrap_or(0);
        // Up, and through a gateway
        if flags & 0x3 != 0x3 {
            continue;
        }
        let gateway = u32::from_str_radix(fields[2], 16).ok()?;
        let metric: u32 = fields[6].parse().unwrap_or(u32::MAX);
        let address = Ipv4Addr::from(gateway.swap_bytes());
        if best.as_ref().is_none_or(|(m, _, _)| metric < *m) {
            best = Some((metric, address, fields[0].to_string()));
        }
    }
    best.map(|(_, address, iface)| (address, iface))
}

/// An unprivileged ICMP echo socket; the kernel sets the identifier and the
/// checksum. Allowed for the groups in net.ipv4.ping_group_range.
struct Pinger {
    fd: i32,
    sequence: u16,
}

impl Pinger {
    fn open() -> Result<Pinger, String> {
        let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, libc::IPPROTO_ICMP) };
        if fd < 0 {
            return Err(format!(
                "can't open a ping socket ({}); is net.ipv4.ping_group_range open to your group?",
                std::io::Error::last_os_error()
            ));
        }
        Ok(Pinger { fd, sequence: 0 })
    }

    /// The round trip to `target` in ms, or None if no answer came in time
    fn ping(&mut self, target: Ipv4Addr) -> Option<f64> {
        self.sequence = self.sequence.wrapping_add(1);
        let mut packet = [0u8; 16];
        packet[0] = 8; // echo request
        packet[6..8].copy_from_slice(&self.sequence.to_be_bytes());
        let address = libc::sockaddr_in {
            sin_family: libc::AF_INET as libc::sa_family_t,
            sin_port: 0,
            sin_addr: libc::in_addr { s_addr: u32::from(target).to_be() },
            sin_zero: [0; 8],
        };
        let started = Instant::now();
        let sent = unsafe {
            libc::sendto(
                self.fd,
                packet.as_ptr().cast(),
                packet.len(),
                0,
                (&address as *const libc::sockaddr_in).cast(),
                mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        };
        if sent < 0 {
            return None;
        }
        let mut reply = [0u8; 64];
        loop {
            let left = PING_TIMEOUT.checked_sub(started.elapsed())?;
            let mut poll = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
            let ready = unsafe { libc::poll(&mut poll, 1, left.as_millis().max(1) as i32) };
            if ready <= 0 {
                return None;
            }
            let read = unsafe { libc::recv(self.fd, reply.as_mut_ptr().cast(), reply.len(), libc::MSG_DONTWAIT) };
            // An echo reply to this request; anything else (a late reply to
            // an earlier one) is passed over
            if read >= 8 && reply[0] == 0 && u16::from_be_bytes([reply[6], reply[7]]) == self.sequence {
                return Some(started.elapsed().as_secs_f64() * 1000.0);
            }
        }
    }
}

impl Drop for Pinger {
    fn drop(&mut self) {
        unsafe { libc::close(self.fd) };
    }
}

/// A TCP handshake's time to one anchor, opened and closed with nothing sent
fn handshake(anchor: &str) -> Option<f64> {
    let address: SocketAddr = anchor.parse().ok()?;
    let started = Instant::now();
    let stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT).ok()?;
    let rtt = started.elapsed().as_secs_f64() * 1000.0;
    drop(stream);
    Some(rtt)
}

/// The internet's round trip: the quicker anchor, both at once. A handshake
/// that only completed after a retransmit counts as a lost packet.
fn internet() -> Option<f64> {
    let results: Vec<Option<f64>> = thread::scope(|scope| {
        let handles: Vec<_> = ANCHORS.iter().map(|anchor| scope.spawn(move || handshake(anchor))).collect();
        handles.into_iter().map(|handle| handle.join().ok().flatten()).collect()
    });
    results.into_iter().flatten().filter(|rtt| *rtt < RETRANSMIT_MS).min_by(f64::total_cmp)
}

// ------------------------------------------------------------------ status

fn runtime_file() -> PathBuf {
    std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir()).join("neko/netlegs.json")
}

fn events_file() -> PathBuf {
    let base = std::env::var("XDG_STATE_HOME")
        .ok()
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    base.join("neko/netlegs-events.json")
}

fn write_atomic(path: &PathBuf, text: &str) {
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let temp = path.with_extension("json.new");
    if fs::write(&temp, text).is_ok() {
        let _ = fs::rename(&temp, path);
    }
}

/// Which side is down, if either: the router not answering is this
/// network's; the router answering and the internet not is the provider's
fn outage_side(local: &Series, internet: &Series, now: i64) -> Option<&'static str> {
    let from = now - OUTAGE_S * 1000;
    if local.all_lost_since(from) {
        Some("local")
    } else if internet.all_lost_since(from) {
        Some("internet")
    } else {
        None
    }
}

/// ok, slow (a leg's loss or lag past what feels fine), or down
fn status(side: Option<&str>, local: &Value, provider: &Value) -> &'static str {
    if side.is_some() {
        return "down";
    }
    let bad = |figures: &Value, lag: f64| {
        figures.get("loss").and_then(Value::as_f64).unwrap_or(0.0) > 0.02
            || figures.get("p95").and_then(Value::as_f64).unwrap_or(0.0) > lag
    };
    if bad(local, 50.0) || bad(provider, 150.0) { "slow" } else { "ok" }
}

fn run() -> Result<(), String> {
    let mut pinger = Pinger::open()?;
    let mut local = Series::default();
    let mut internet_series = Series::default();
    let mut provider = Series::default();
    let mut events: Vec<Value> = fs::read_to_string(events_file())
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    let mut ongoing: Option<(&'static str, i64)> = None;
    let mut route: Option<(Ipv4Addr, String)> = None;

    loop {
        let started = Instant::now();
        let now = now_ms();

        // A new network starts its figures over
        let current = default_gateway();
        if current != route {
            local = Series::default();
            internet_series = Series::default();
            provider = Series::default();
            route = current.clone();
        }

        let (local_rtt, internet_rtt) = thread::scope(|scope| {
            let internet_probe = scope.spawn(internet);
            let local_rtt = route.as_ref().and_then(|(gateway, _)| pinger.ping(*gateway));
            (local_rtt, internet_probe.join().ok().flatten())
        });
        local.add(now, local_rtt);
        internet_series.add(now, internet_rtt);
        // The provider's share: what the internet took past the router. With
        // the router silent it can't be told apart, so it isn't recorded.
        if let Some(local_ms) = local_rtt {
            provider.add(now, internet_rtt.map(|internet_ms| (internet_ms - local_ms).max(0.0)));
        }

        // Outages, as they start and end
        let side = outage_side(&local, &internet_series, now);
        match (ongoing, side) {
            (None, Some(side)) => ongoing = Some((side, now - OUTAGE_S * 1000)),
            (Some((was, since)), now_side) if now_side != Some(was) => {
                events.push(json!({ "side": was, "start": since, "end": now, "seconds": (now - since) / 1000 }));
                if events.len() > MAX_EVENTS {
                    events.drain(..events.len() - MAX_EVENTS);
                }
                write_atomic(&events_file(), &serde_json::to_string_pretty(&events).unwrap_or_default());
                ongoing = now_side.map(|side| (side, now - OUTAGE_S * 1000));
            }
            _ => {}
        }

        let from = now - RECENT_S * 1000;
        let local_figures = stats(&local.since(from));
        let provider_figures = stats(&provider.since(from));
        let state = json!({
            "running": true,
            "updatedAt": now,
            "gateway": route.as_ref().map(|(gateway, _)| gateway.to_string()),
            "iface": route.as_ref().map(|(_, iface)| iface.clone()),
            "status": if route.is_none() { "offline" } else { status(side, &local_figures, &provider_figures) },
            "outage": ongoing.map(|(side, since)| json!({ "side": side, "since": since })),
            "legs": {
                "local": local_figures,
                "provider": provider_figures,
                "internet": stats(&internet_series.since(from)),
            },
            "history": {
                "local": local.minutes(now),
                "provider": provider.minutes(now),
            },
            "events": events.iter().rev().take(10).cloned().collect::<Vec<_>>(),
        });
        write_atomic(&runtime_file(), &state.to_string());

        if let Some(rest) = TICK.checked_sub(started.elapsed()) {
            sleep(rest);
        }
    }
}

fn start() -> Result<(), String> {
    let active = Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", &format!("{UNIT}.service")])
        .status()
        .is_ok_and(|status| status.success());
    if active {
        return Ok(());
    }
    let program = std::env::current_exe().map_err(|error| format!("can't find neko-core: {error}"))?;
    let status = Command::new("systemd-run")
        .args(["--user", "--quiet", &format!("--unit={UNIT}"), "--property=Restart=on-failure", "--property=RestartSec=10"])
        .arg(program)
        .args(["netlegs", "run"])
        .stdout(Stdio::null())
        .status()
        .map_err(|error| format!("can't run systemd-run: {error}"))?;
    if status.success() { Ok(()) } else { Err("systemd-run couldn't start neko-netlegs".into()) }
}

fn report() -> Result<(), String> {
    let events: Vec<Value> = fs::read_to_string(events_file())
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    if events.is_empty() {
        println!("No outages logged.");
        return Ok(());
    }
    println!("Outages logged by neko (newest first):");
    for event in events.iter().rev() {
        let start = event.get("start").and_then(Value::as_i64).unwrap_or(0);
        let seconds = event.get("seconds").and_then(Value::as_i64).unwrap_or(0);
        let when = chrono::DateTime::from_timestamp_millis(start)
            .map(|time| time.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M:%S").to_string())
            .unwrap_or_default();
        let side = match event.get("side").and_then(Value::as_str) {
            Some("local") => "local network (the router stopped answering)",
            _ => "internet provider (the router answered; the internet didn't)",
        };
        println!("  {when}  {}m {:02}s  {side}", seconds / 60, seconds % 60);
    }
    Ok(())
}

pub fn run_command(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("run") => run(),
        Some("start") => start(),
        Some("stop") => {
            let _ = Command::new("systemctl")
                .args(["--user", "stop", &format!("{UNIT}.service")])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            Ok(())
        }
        Some("state") => {
            let text = fs::read_to_string(runtime_file()).map_err(|_| "neko-netlegs isn't running (neko netlegs start)".to_string())?;
            println!("{}", text.trim());
            Ok(())
        }
        Some("report") => report(),
        _ => Err("usage: neko-core netlegs <run|start|stop|state|report>".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn figures_over_some_samples() {
        let samples: Vec<Sample> = vec![(0, Some(10.0)), (1, Some(40.0)), (2, None), (3, Some(10.0)), (4, Some(40.0))];
        let figures = stats(&samples);
        assert_eq!(figures["count"], 5);
        assert_eq!(figures["loss"], 0.2);
        assert_eq!(figures["p50"], 25.0);
        assert_eq!(figures["p95"], 40.0);
        // IPDV over the replies: |40-10|, |10-40|, |40-10|
        assert_eq!(figures["jitter"], 30.0);
        assert_eq!(figures["last"], 40.0);
    }

    #[test]
    fn nothing_answered() {
        let figures = stats(&[(0, None), (1, None)]);
        assert_eq!(figures["loss"], 1.0);
        assert!(figures.get("p50").is_none());
    }

    #[test]
    fn which_side_is_down() {
        let mut local = Series::default();
        let mut internet = Series::default();
        for t in 0..10 {
            local.add(t * 1000, Some(1.0));
            internet.add(t * 1000, None);
        }
        assert_eq!(outage_side(&local, &internet, 9_000), Some("internet"));
        for t in 10..20 {
            local.add(t * 1000, None);
        }
        assert_eq!(outage_side(&local, &internet, 19_000), Some("local"));
    }

    #[test]
    fn slow_or_fine() {
        let fine = json!({ "loss": 0.0, "p95": 3.0 });
        let lossy = json!({ "loss": 0.05, "p95": 3.0 });
        assert_eq!(status(None, &fine, &fine), "ok");
        assert_eq!(status(None, &lossy, &fine), "slow");
        assert_eq!(status(Some("local"), &fine, &fine), "down");
    }
}
