//! neko-core: the parts of neko that do real work outside the shell, in one
//! binary. Each `bin/neko-*` command it replaces is a thin wrapper that runs
//! `neko-core <subcommand>`, so nothing else in neko notices the switch.

mod agents;
mod bitwarden;
mod calendar;
mod clock;
mod displayprofile;
mod faceauth;
mod filepick;
mod netlegs;
mod record;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        eprintln!("Usage: neko-core <subcommand> [args...]");
        return ExitCode::from(2);
    };
    let result = match command.as_str() {
        // What install.sh compares against the checkout's version
        "version" | "--version" => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "bitwarden" => bitwarden::run(rest),
        "calendar-events" => calendar::run(rest),
        "clock" => clock::run(rest),
        "display-profile" => displayprofile::run(rest),
        "faceauth-watch" => faceauth::run(rest),
        "file-select" => filepick::run(rest),
        "netlegs" => netlegs::run_command(rest),
        "record" => record::run(rest),
        "agent-account-state" => agents::accounts::run(rest),
        "agent-usage-claude" => agents::claude::run(rest),
        "agent-usage-codex" => agents::codex::run(rest),
        "agent-usage-fireworks" => agents::fireworks::run(rest),
        "agent-usage-grok" => agents::grok::run(rest),
        other => Err(format!("unknown subcommand: {other}")),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("neko-core {command}: {error}");
            ExitCode::FAILURE
        }
    }
}
