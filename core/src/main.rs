//! neko-core: the parts of neko that do real work outside the shell, in one
//! binary. Each `bin/neko-*` command it replaces is a thin wrapper that runs
//! `neko-core <subcommand>`, so nothing else in neko notices the switch.

mod calendar;
mod faceauth;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        eprintln!("Usage: neko-core <calendar-events|faceauth-watch> [args...]");
        return ExitCode::from(2);
    };
    let result = match command.as_str() {
        "calendar-events" => calendar::run(rest),
        "faceauth-watch" => faceauth::run(rest),
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
