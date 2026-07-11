//! Tiny dependency-free CLI parser: where to point the TUI (`.work/` directory) and a couple of
//! knobs. No `clap` — the surface is one path plus two flags, so a hand-rolled parser keeps the
//! dependency set minimal and the first online fetch small.

use std::path::PathBuf;

/// The resolved run configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// Path to the orchestrator's `.work/` directory to observe.
    pub work_dir: PathBuf,
    /// UI refresh / input-poll cadence in milliseconds.
    pub tick_ms: u64,
}

/// Outcome of parsing argv (excluding argv[0]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cli {
    /// Run with this config.
    Run(Config),
    /// Print this text to stdout and exit 0 (`--help` / `--version`).
    Print(String),
}

/// The default `.work/` location: the project's `.work` relative to the current directory.
const DEFAULT_WORK_DIR: &str = ".work";
const DEFAULT_TICK_MS: u64 = 250;

pub fn usage() -> String {
    // Built line-by-line (not one `\`-continued literal) so the intended indentation survives —
    // a `\`-newline in a Rust string literal also swallows the next line's leading whitespace.
    let mut s = String::new();
    s.push_str("orchestra-tui — read-only live overview of a running orchestrator (plan §6.1)\n\n");
    s.push_str("USAGE:\n");
    s.push_str("    orchestra-tui [OPTIONS] [WORK_DIR]\n\n");
    s.push_str("ARGS:\n");
    s.push_str("    [WORK_DIR]           Path to the orchestrator's .work/ directory\n");
    s.push_str(&format!(
        "                         (default: {DEFAULT_WORK_DIR} relative to the current directory)\n\n"
    ));
    s.push_str("OPTIONS:\n");
    s.push_str("    -w, --work <PATH>    Same as the positional WORK_DIR argument\n");
    s.push_str(&format!(
        "        --tick-ms <N>    UI refresh / input cadence in ms (default: {DEFAULT_TICK_MS})\n"
    ));
    s.push_str("    -h, --help           Print this help and exit\n");
    s.push_str("    -V, --version        Print version and exit\n\n");
    s.push_str(
        "The TUI is strictly read-only: it tails <WORK_DIR>/events.jsonl and reads \
<WORK_DIR>/status.md,\nand never writes, locks, or otherwise touches the running orchestrator.\n\n",
    );
    s.push_str("KEYS:  q / Esc quit   ·   r reload status.md\n");
    s
}

/// Parse argv (already stripped of the program name). Returns [`Cli`] or a human-readable error.
pub fn parse<I: IntoIterator<Item = String>>(args: I) -> Result<Cli, String> {
    let mut work_dir: Option<PathBuf> = None;
    let mut tick_ms: u64 = DEFAULT_TICK_MS;

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(Cli::Print(usage())),
            "-V" | "--version" => {
                return Ok(Cli::Print(format!(
                    "orchestra-tui {}\n",
                    env!("CARGO_PKG_VERSION")
                )))
            }
            "-w" | "--work" => {
                let v = it
                    .next()
                    .ok_or_else(|| format!("{arg} requires a path argument"))?;
                work_dir = Some(PathBuf::from(v));
            }
            "--tick-ms" => {
                let v = it
                    .next()
                    .ok_or_else(|| "--tick-ms requires a number".to_string())?;
                tick_ms = v
                    .parse::<u64>()
                    .map_err(|_| format!("--tick-ms: '{v}' is not a non-negative integer"))?;
                if tick_ms == 0 {
                    return Err("--tick-ms must be greater than 0".to_string());
                }
            }
            other if other.starts_with('-') && other != "-" => {
                return Err(format!("unknown option '{other}' (try --help)"));
            }
            positional => {
                if work_dir.is_some() {
                    return Err(format!(
                        "unexpected extra argument '{positional}' (WORK_DIR already given)"
                    ));
                }
                work_dir = Some(PathBuf::from(positional));
            }
        }
    }

    Ok(Cli::Run(Config {
        work_dir: work_dir.unwrap_or_else(|| PathBuf::from(DEFAULT_WORK_DIR)),
        tick_ms,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    fn run(a: &[&str]) -> Config {
        match parse(args(a)).unwrap() {
            Cli::Run(c) => c,
            Cli::Print(_) => panic!("expected Run, got Print"),
        }
    }

    #[test]
    fn default_work_dir_is_dot_work() {
        let c = run(&[]);
        assert_eq!(c.work_dir, PathBuf::from(".work"));
        assert_eq!(c.tick_ms, DEFAULT_TICK_MS);
    }

    #[test]
    fn positional_and_flag_both_set_work_dir() {
        assert_eq!(run(&["/srv/repo/.work"]).work_dir, PathBuf::from("/srv/repo/.work"));
        assert_eq!(run(&["--work", "/x/.work"]).work_dir, PathBuf::from("/x/.work"));
        assert_eq!(run(&["-w", "/y/.work"]).work_dir, PathBuf::from("/y/.work"));
    }

    #[test]
    fn tick_ms_parsed_and_validated() {
        assert_eq!(run(&["--tick-ms", "500"]).tick_ms, 500);
        assert!(parse(args(&["--tick-ms", "0"])).is_err());
        assert!(parse(args(&["--tick-ms", "abc"])).is_err());
    }

    #[test]
    fn help_and_version_print() {
        assert!(matches!(parse(args(&["--help"])).unwrap(), Cli::Print(_)));
        assert!(matches!(parse(args(&["-h"])).unwrap(), Cli::Print(_)));
        assert!(matches!(parse(args(&["--version"])).unwrap(), Cli::Print(_)));
    }

    #[test]
    fn unknown_flag_and_double_positional_error() {
        assert!(parse(args(&["--bogus"])).is_err());
        assert!(parse(args(&["a", "b"])).is_err());
    }
}
