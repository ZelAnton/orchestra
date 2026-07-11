//! Safe terminal setup / teardown so the operator's terminal is ALWAYS restored — on a normal
//! quit, on an error return, and on a panic. Leaving raw mode / the alternate screen engaged would
//! wedge the user's shell, so restoration is wired three ways:
//!
//! * [`init`] enters raw mode + the alternate screen and hands back a ready [`Tui`].
//! * [`TerminalGuard`]'s `Drop` calls [`restore`] on any scope exit (normal or `?`-error).
//! * [`install_panic_hook`] restores the terminal *before* the default panic handler prints, so a
//!   panic backtrace lands on a sane screen instead of a raw-mode-mangled one.
//!
//! All three restore paths are best-effort (`let _ =`): teardown must never itself panic.

use std::io::{self, Stdout};

use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

/// The concrete terminal type this app draws to.
pub type Tui = Terminal<CrosstermBackend<Stdout>>;

/// Enter raw mode + the alternate screen and return a cleared, ready terminal.
pub fn init() -> io::Result<Tui> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    terminal.clear()?;
    Ok(terminal)
}

/// Leave the alternate screen and disable raw mode. Idempotent / best-effort per call.
pub fn restore() -> io::Result<()> {
    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    Ok(())
}

/// RAII guard: restores the terminal when it drops, covering both the normal-exit and the
/// `?`-early-return paths without an explicit teardown call at every return site.
pub struct TerminalGuard;

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = restore();
    }
}

/// Chain a terminal-restoring step in front of the existing panic hook, so a panic never leaves
/// the terminal in raw mode. Call this BEFORE [`init`].
pub fn install_panic_hook() {
    let original = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = restore();
        original(info);
    }));
}
