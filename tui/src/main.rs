//! orchestra-tui — a strictly **read-only** live operator overview of a running orchestrator,
//! with two switchable screens (`Tab`): the §6.1 overview and the §6.2 Decision Inbox.
//!
//! It tails `<work>/events.jsonl` through the engine crate's cursor reader
//! ([`orchestra_engine_spike::events::TailReader`] — the SAME reader the future engine uses, so
//! there is no duplicated tail/dedup/torn-tail logic) and folds the `cohort.*` / `task.*` stream
//! into the current batch/cohort/task projection ([`app::AppState`]), overlaying human context
//! from `<work>/status.md` ([`status`]). The Decision Inbox ([`inbox`]) is rebuilt on the same
//! cadence from a fresh [`orchestra_engine_spike::state::Snapshot`] (queue + task descriptors)
//! plus whether `<work>/PAUSE` exists. Nothing here writes a file, takes a lock, creates or
//! checks `orchestrator.lock`, or calls `processor` / `tools/*.ps1` / launchers: this observer
//! runs safely against the LIVE `.work/` of the very orchestra producing those artifacts.
//!
//! The terminal is always restored — normal quit, error return, or panic (see [`terminal`]).

mod app;
mod cli;
mod inbox;
mod status;
mod terminal;
mod ui;

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crossterm::event::{self, Event as CEvent, KeyCode, KeyEventKind, KeyModifiers};
use orchestra_engine_spike::events::TailReader;
use orchestra_engine_spike::state::Snapshot;

use app::AppState;
use cli::{Cli, Config};

fn main() {
    let cfg = match cli::parse(std::env::args().skip(1)) {
        Ok(Cli::Run(cfg)) => cfg,
        Ok(Cli::Print(text)) => {
            print!("{text}");
            return;
        }
        Err(msg) => {
            eprintln!("orchestra-tui: {msg}");
            std::process::exit(2);
        }
    };

    if let Err(e) = run(cfg) {
        // The TerminalGuard in `run` has already restored the terminal by the time we get here.
        eprintln!("orchestra-tui: {e}");
        std::process::exit(1);
    }
}

fn run(cfg: Config) -> io::Result<()> {
    let events_path: PathBuf = cfg.work_dir.join("events.jsonl");
    let status_path: PathBuf = cfg.work_dir.join("status.md");

    let mut reader = TailReader::new(&events_path);
    let mut app = AppState::new();
    // Prime the projection with everything already in the journal (a cold observer of a
    // long-running orchestra) before drawing the first frame.
    app.apply_all(&reader.poll()?);
    app.status = status::load(&status_path);
    app.inbox = load_inbox(&cfg.work_dir);

    terminal::install_panic_hook();
    let mut term = terminal::init()?;
    let _guard = terminal::TerminalGuard; // restores on any exit path

    let tick = Duration::from_millis(cfg.tick_ms);
    let status_reload_every = Duration::from_millis(500);
    let mut last_status_reload = Instant::now();

    loop {
        // 1. Pull any newly-appended events (cursor reader: only new, unique, committed lines).
        let new = reader.poll()?;
        if !new.is_empty() {
            app.apply_all(&new);
        }

        // 2. Refresh the status.md overlay and the Decision Inbox on a gentle cadence (small
        // reads, cheap, read-only — no lock, never writes).
        if last_status_reload.elapsed() >= status_reload_every {
            app.status = status::load(&status_path);
            app.inbox = load_inbox(&cfg.work_dir);
            last_status_reload = Instant::now();
        }

        // 3. Paint.
        term.draw(|f| ui::render(f, &app))?;

        // 4. Handle input, blocking up to one tick so the loop also serves as the refresh timer.
        if event::poll(tick)? {
            match event::read()? {
                CEvent::Key(k) if k.kind == KeyEventKind::Press => match k.code {
                    KeyCode::Char('q') | KeyCode::Esc => break,
                    KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => break,
                    KeyCode::Tab => app.toggle_screen(),
                    KeyCode::Char('r') => {
                        app.status = status::load(&status_path);
                        app.inbox = load_inbox(&cfg.work_dir);
                        last_status_reload = Instant::now();
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }

    Ok(())
}

/// Build the Decision Inbox (§6.2) from the current `.work/` contents: a fresh, read-only
/// `Snapshot` (queue + task descriptors) plus whether `.work/PAUSE` currently exists. Only the
/// pause file's *existence* is meaningful (see `agents/processor.md`, "Пауза — kill switch
/// `.work/PAUSE`"); its content, if any, is carried through as an informational note only.
fn load_inbox(work_dir: &Path) -> inbox::DecisionInbox {
    let snapshot = Snapshot::load(work_dir);
    let pause_path = work_dir.join("PAUSE");
    let paused = pause_path.exists();
    let pause_note = if paused {
        std::fs::read_to_string(&pause_path)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    } else {
        None
    };
    inbox::build(&snapshot, paused, pause_note)
}
