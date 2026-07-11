//! The TUI's small, safe **command channel "downward"** to a running orchestrator (intent doc
//! §5 / §6.2). Everything else in this crate only *observes* `.work/`; this module is the sole
//! exception, and it is deliberately narrow: it may touch **only** `.work/PAUSE` and
//! `.work/orchestrator.lock`, and it does so by *mirroring the existing launchers/tools* rather
//! than inventing a parallel backend.
//!
//! Four commands, each a faithful mirror of a mechanism that already exists:
//!
//! * **pause** — create `.work/PAUSE` (the kill switch checked at a phase/round boundary), the
//!   same file `launchers/cc-pause.sh` writes. A running processor only checks that the file
//!   *exists*; its body is purely informational (see `agents/processor.md`, "Пауза — kill switch
//!   `.work/PAUSE`").
//! * **resume** — remove `.work/PAUSE`, mirroring `launchers/cc-unpause.sh` (tolerant of an
//!   already-absent file — that is *not* an error).
//! * **lease-status** — read who owns `.work/orchestrator.lock` and whether the lease is live,
//!   strictly through the **existing owner-checked read path**: the engine crate's `lease` module
//!   (`orchestra_engine_spike::lease`, task T-107) which delegates to `tools/state-tx.ps1 status
//!   --json` and *nothing else* (KB K-003). We reuse its argv builder + supervised spawn rather
//!   than shelling out to a separate `engine` binary or re-implementing any `lease.json` reading.
//! * **force-lock** — remove the whole `.work/orchestrator.lock` directory, mirroring exactly what
//!   `launchers/cc-processor.sh --force-lock` does (`rm -rf .work/orchestrator.lock`) — no other
//!   side effect. This is the one destructive command; the caller (see `main.rs` / `app::Modal`)
//!   guards it behind an explicit confirmation. We deliberately do **not** route force-lock through
//!   the `engine lease` API: that path is owner-checked and never force-removes a lease (K-003), so
//!   the operator-only "processor is definitely dead, take the lock by hand" action must mirror the
//!   launcher directly.
//!
//! **Testable core.** As with [`crate::app`], the decision/format/parse logic here is pure and
//! unit-tested without a terminal; the only impure pieces are the three thin filesystem writes
//! (`pause` / `resume` / `force_lock`) and the supervised `state-tx.ps1` spawn in
//! [`query_lease_status`]. Callers never issue any command implicitly — a keystroke in `main.rs`
//! is what triggers one, and force-lock additionally requires the confirmation gate.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use orchestra_engine_spike::lease;

/// The pause kill switch, relative to the `.work/` directory.
const PAUSE_FILE: &str = "PAUSE";
/// The owner-lease directory, relative to the `.work/` directory.
const LOCK_DIR: &str = "orchestrator.lock";

// ---------------------------------------------------------------------------------------------
// pause / resume — direct `.work/PAUSE` writes mirroring cc-pause.sh / cc-unpause.sh
// ---------------------------------------------------------------------------------------------

/// The body written into `.work/PAUSE`, mirroring `launchers/cc-pause.sh`: a `paused_at=<ISO-8601
/// UTC>` line, plus the launcher's optional `reason=` line (here recording the TUI as the source,
/// so an operator inspecting the file later can tell a TUI-raised pause from a `cc-pause` one).
/// Pure so the format is unit-tested against a fixed timestamp; only the file *existence* matters
/// to the processor, so the exact body is informational.
pub fn pause_body(now_iso8601: &str) -> String {
    format!("paused_at={now_iso8601}\nreason=paused from orchestra-tui\n")
}

/// **pause**: create (or overwrite) `<work>/PAUSE` with [`pause_body`]. Mirrors `cc-pause.sh`'s
/// direct file write — no external process is spawned. Returns the path written.
pub fn pause(work_dir: &Path, now_iso8601: &str) -> io::Result<PathBuf> {
    let path = work_dir.join(PAUSE_FILE);
    fs::write(&path, pause_body(now_iso8601))?;
    Ok(path)
}

/// **resume**: remove `<work>/PAUSE`, mirroring `cc-unpause.sh`. Tolerant of an already-absent
/// file (that is *not* an error — nothing to clear). Returns `true` if a file was actually
/// removed, `false` if there was nothing to clear.
pub fn resume(work_dir: &Path) -> io::Result<bool> {
    let path = work_dir.join(PAUSE_FILE);
    match fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

// ---------------------------------------------------------------------------------------------
// force-lock — mirror of `cc-processor.sh --force-lock` (rm -rf .work/orchestrator.lock)
// ---------------------------------------------------------------------------------------------

/// **force-lock**: remove the whole `<work>/orchestrator.lock` directory (lease record included),
/// mirroring exactly `launchers/cc-processor.sh --force-lock` (`rm -rf .work/orchestrator.lock`) —
/// no other side effect. Tolerant of an already-absent directory. Returns `true` if a lock
/// directory was actually removed. **Destructive**: the caller must have obtained explicit operator
/// confirmation first (see `app::Modal` / `main.rs`); this function does not itself gate on that —
/// the confirmation is a UI concern kept separate so the removal stays a small, testable unit.
pub fn force_lock(work_dir: &Path) -> io::Result<bool> {
    let path = work_dir.join(LOCK_DIR);
    match fs::remove_dir_all(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

// ---------------------------------------------------------------------------------------------
// lease-status — via the engine crate's owner-checked `tools/state-tx.ps1 status --json` path
// ---------------------------------------------------------------------------------------------

/// A structured, valid lease read from `.work/orchestrator.lock/lease.json` (via `state-tx.ps1
/// status --json`). Fields are `None` when the underlying JSON omits them, never invented.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LeasePresent {
    pub role: Option<String>,
    pub owner_id: Option<String>,
    pub host: Option<String>,
    pub pid: Option<i64>,
    /// Whether the holder is provably live (pid / heartbeat-vs-TTL, decided by `state-tx.ps1`).
    pub live: bool,
    pub heartbeat_age_secs: Option<i64>,
    pub ttl_seconds: Option<i64>,
    pub generation: Option<i64>,
    /// The human liveness reason string from `state-tx.ps1` (e.g. "pid 1234 alive …").
    pub reason: Option<String>,
}

/// The outcome of a lease-status query — one of the `state-tx.ps1 status` shapes, or an
/// unavailable query (no PowerShell host / script not found / spawn or timeout failure). Read-only
/// throughout: nothing here mutates the lock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LeaseStatus {
    /// The query itself could not run (e.g. `state-tx.ps1`/pwsh missing, spawn failure, timeout).
    Unavailable(String),
    /// No lease at all — `.work/orchestrator.lock` is free (`{present:false}`, state-tx exit 14).
    Absent,
    /// A lock directory exists but is not a structured lease we can read: a legacy `mkdir` lock or
    /// a corrupt `lease.json` (state-tx exit 19 / 18). The string carries the detail.
    Degraded(String),
    /// A structured, valid lease was read.
    Present(LeasePresent),
}

impl LeaseStatus {
    /// A one-line human summary for the overlay/footer.
    pub fn summary(&self) -> String {
        match self {
            LeaseStatus::Unavailable(why) => format!("аренда: запрос недоступен ({why})"),
            LeaseStatus::Absent => "аренда: свободна — .work/orchestrator.lock отсутствует".to_string(),
            LeaseStatus::Degraded(detail) => format!("аренда: нечитаемый замок ({detail})"),
            LeaseStatus::Present(l) => {
                let who = l.owner_id.as_deref().unwrap_or("?");
                let role = l.role.as_deref().unwrap_or("?");
                let liveness = if l.live { "жива" } else { "устарела" };
                format!("аренда: {liveness} · владелец {who} · роль {role}")
            }
        }
    }
}

/// Pure parse of the `state-tx.ps1 status --json` stdout into a [`LeaseStatus`]. The JSON is
/// self-describing (`present` / `valid` / `legacy`), so the classification needs no exit code.
/// Empty or unparseable output degrades to [`LeaseStatus::Unavailable`] rather than panicking —
/// the same "total loading" leniency as the rest of this observer.
pub fn parse_lease_status(stdout: &str) -> LeaseStatus {
    let text = stdout.trim();
    if text.is_empty() {
        return LeaseStatus::Unavailable("пустой ответ state-tx".to_string());
    }
    let v: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => return LeaseStatus::Unavailable(format!("нераспознанный JSON: {e}")),
    };
    let present = v.get("present").and_then(|x| x.as_bool()).unwrap_or(false);
    if !present {
        return LeaseStatus::Absent;
    }
    let valid = v.get("valid").and_then(|x| x.as_bool()).unwrap_or(false);
    if !valid {
        let err = v
            .get("error")
            .and_then(|x| x.as_str())
            .unwrap_or("нет деталей");
        let legacy = v.get("legacy").and_then(|x| x.as_bool()).unwrap_or(false);
        let kind = if legacy { "legacy-lock" } else { "corrupt-lease" };
        return LeaseStatus::Degraded(format!("{kind}: {err}"));
    }
    LeaseStatus::Present(LeasePresent {
        role: json_str(&v, "role"),
        owner_id: json_str(&v, "owner_id"),
        host: json_str(&v, "host"),
        pid: json_i64(&v, "pid"),
        live: v.get("live").and_then(|x| x.as_bool()).unwrap_or(false),
        heartbeat_age_secs: json_i64(&v, "heartbeat_age_secs"),
        ttl_seconds: json_i64(&v, "ttl_seconds"),
        generation: json_i64(&v, "generation"),
        reason: json_str(&v, "reason"),
    })
}

fn json_str(v: &serde_json::Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(str::to_string)
}

fn json_i64(v: &serde_json::Value, key: &str) -> Option<i64> {
    v.get(key).and_then(|x| x.as_i64())
}

/// Resolve the `state-tx.ps1` runner for the observed project, following the single "checkout vs
/// mirror" rule (see `knowledge.md`, "Резолвинг раннеров `tools/*.ps1`"): prefer the project's own
/// `<root>/tools/state-tx.ps1` (root = the `.work/` parent), else fall back to the cc-sync mirror
/// at `~/.claude/scripts/state-tx.ps1`. `None` if neither exists — the caller surfaces that as
/// [`LeaseStatus::Unavailable`] instead of guessing.
pub fn resolve_state_tx_script(work_dir: &Path) -> Option<PathBuf> {
    if let Some(root) = work_dir.parent() {
        let checkout = root.join("tools").join("state-tx.ps1");
        if checkout.exists() {
            return Some(checkout);
        }
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)?;
    let mirror = home.join(".claude").join("scripts").join("state-tx.ps1");
    if mirror.exists() {
        Some(mirror)
    } else {
        None
    }
}

/// **lease-status** (impure): run `state-tx.ps1 status --work <dir> --json` through the engine
/// crate's owner-checked lease helpers ([`lease::status_argv`] + [`lease::run_state_tx`], the same
/// supervised spawn `engine lease status` uses) and classify the result. Read-only: `status` never
/// mutates the lock. Any inability to run the query is returned as [`LeaseStatus::Unavailable`],
/// never a panic.
pub fn query_lease_status(work_dir: &Path) -> LeaseStatus {
    let script = match resolve_state_tx_script(work_dir) {
        Some(s) => s,
        None => {
            return LeaseStatus::Unavailable(
                "state-tx.ps1 не найден (ни в <root>/tools, ни в зеркале ~/.claude/scripts)"
                    .to_string(),
            )
        }
    };
    let work_s = work_dir.to_string_lossy().into_owned();
    let script_s = script.to_string_lossy().into_owned();
    let argv = lease::status_argv(&work_s, true);
    match lease::run_state_tx(&script_s, &argv, lease::STATE_TX_DEADLINE) {
        Err(e) => LeaseStatus::Unavailable(e),
        Ok(v) => {
            if v.exit_code.is_none() {
                return LeaseStatus::Unavailable(format!(
                    "state-tx не завершился: {} — {}",
                    v.reason.as_str(),
                    v.outcome_reason
                ));
            }
            let out = v.stdout.trim();
            if out.is_empty() {
                let why = v
                    .stderr
                    .lines()
                    .map(str::trim)
                    .find(|l| !l.is_empty())
                    .unwrap_or("нет вывода");
                return LeaseStatus::Unavailable(why.to_string());
            }
            parse_lease_status(out)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// ISO-8601 UTC timestamp — a tiny, dependency-free civil-from-days converter (no chrono, so the
// crate stays offline/dependency-light, matching the engine's "dependency-free on purpose" line).
// ---------------------------------------------------------------------------------------------

/// The current instant as `YYYY-MM-DDTHH:MM:SSZ` (the same shape `cc-pause.sh`'s `date -u` emits).
/// Falls back to the Unix epoch string if the clock is somehow before 1970 (it never is).
pub fn now_iso8601() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    epoch_to_iso8601(secs)
}

/// Convert Unix epoch seconds (UTC) to `YYYY-MM-DDTHH:MM:SSZ`. Pure — uses Howard Hinnant's
/// `civil_from_days` algorithm so it needs no calendar library and is trivially unit-tested
/// against known instants.
pub fn epoch_to_iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = (secs % 86_400) as i64;
    let (hour, minute, second) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    // civil_from_days: shift the epoch so the internal year begins on 1 March.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let day = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let month = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let year = if month <= 2 { y + 1 } else { y };

    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TmpWork {
        dir: PathBuf,
    }
    impl TmpWork {
        fn new() -> TmpWork {
            static COUNTER: AtomicU64 = AtomicU64::new(0);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let n = COUNTER.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!(
                "orchestra-tui-cmd-{}-{nanos}-{n}",
                std::process::id()
            ));
            fs::create_dir_all(&dir).unwrap();
            TmpWork { dir }
        }
    }
    impl Drop for TmpWork {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn pause_body_mirrors_cc_pause_format() {
        let body = pause_body("2026-07-12T01:09:08Z");
        // cc-pause.sh writes `paused_at=<date -u>` first…
        assert!(body.starts_with("paused_at=2026-07-12T01:09:08Z\n"));
        // …plus the optional `reason=` line the launcher supports.
        assert!(body.contains("reason=paused from orchestra-tui"));
        // trailing newline, like the shell heredoc.
        assert!(body.ends_with('\n'));
    }

    #[test]
    fn pause_creates_the_kill_switch() {
        let w = TmpWork::new();
        assert!(!w.dir.join("PAUSE").exists());
        let p = pause(&w.dir, "2026-07-12T01:09:08Z").unwrap();
        assert_eq!(p, w.dir.join("PAUSE"));
        let body = fs::read_to_string(&p).unwrap();
        assert!(body.contains("paused_at=2026-07-12T01:09:08Z"));
    }

    #[test]
    fn resume_removes_pause_and_tolerates_absence() {
        let w = TmpWork::new();
        // Nothing to clear yet -> Ok(false), not an error (mirrors cc-unpause.sh).
        assert!(!resume(&w.dir).unwrap(), "nothing to clear yet");
        pause(&w.dir, "2026-07-12T01:09:08Z").unwrap();
        assert!(w.dir.join("PAUSE").exists());
        // Now there is something to clear -> Ok(true).
        assert!(resume(&w.dir).unwrap(), "PAUSE was present and removed");
        assert!(!w.dir.join("PAUSE").exists());
        // Second resume is again a harmless no-op.
        assert!(!resume(&w.dir).unwrap(), "already cleared");
    }

    #[test]
    fn force_lock_removes_the_whole_lock_dir_and_tolerates_absence() {
        let w = TmpWork::new();
        // Absent lock -> Ok(false), not an error.
        assert!(!force_lock(&w.dir).unwrap(), "no lock to remove yet");
        // Build a lock dir with a lease.json inside, like the real orchestrator.lock.
        let lock = w.dir.join("orchestrator.lock");
        fs::create_dir_all(&lock).unwrap();
        fs::write(lock.join("lease.json"), "{\"role\":\"processor\"}").unwrap();
        assert!(lock.exists());
        // force-lock removes the directory whole (rm -rf), like cc-processor.sh --force-lock.
        assert!(force_lock(&w.dir).unwrap(), "existing lock dir removed");
        assert!(!lock.exists());
        // And only the lock: nothing else in .work/ is touched.
        assert!(w.dir.exists());
    }

    #[test]
    fn parse_lease_status_reads_a_live_lease() {
        // The exact shape state-tx.ps1 `status --json` emits for a valid lease.
        let json = r#"{"present":true,"valid":true,"role":"processor","owner_id":"ab12cd34","session_id":"s1","root":"/p","host":"HOSTA","pid":4321,"acquired":"2026-07-12T00:00:00Z","heartbeat":"2026-07-12T01:00:00Z","ttl_seconds":900,"generation":3,"live":true,"liveness_basis":"pid","heartbeat_age_secs":12,"reason":"pid 4321 alive (start-time matches)"}"#;
        match parse_lease_status(json) {
            LeaseStatus::Present(l) => {
                assert_eq!(l.owner_id.as_deref(), Some("ab12cd34"));
                assert_eq!(l.role.as_deref(), Some("processor"));
                assert_eq!(l.host.as_deref(), Some("HOSTA"));
                assert_eq!(l.pid, Some(4321));
                assert!(l.live);
                assert_eq!(l.heartbeat_age_secs, Some(12));
                assert_eq!(l.ttl_seconds, Some(900));
                assert_eq!(l.generation, Some(3));
                assert!(l.reason.as_deref().unwrap().contains("alive"));
            }
            other => panic!("expected Present, got {other:?}"),
        }
    }

    #[test]
    fn parse_lease_status_reads_a_stale_lease() {
        let json = r#"{"present":true,"valid":true,"role":"engine","owner_id":"ff99","host":"HOSTB","pid":7,"ttl_seconds":900,"generation":1,"live":false,"heartbeat_age_secs":4000,"reason":"heartbeat 4000s old >= ttl 900s (expired)"}"#;
        match parse_lease_status(json) {
            LeaseStatus::Present(l) => {
                assert!(!l.live, "stale lease must report live=false");
                assert_eq!(l.owner_id.as_deref(), Some("ff99"));
                assert!(l.reason.as_deref().unwrap().contains("expired"));
            }
            other => panic!("expected Present, got {other:?}"),
        }
    }

    #[test]
    fn parse_lease_status_maps_absent_legacy_and_corrupt() {
        // No lease at all (state-tx exit 14).
        assert_eq!(parse_lease_status(r#"{"present":false}"#), LeaseStatus::Absent);
        // Legacy mkdir lock (exit 19).
        match parse_lease_status(r#"{"present":true,"valid":false,"legacy":true,"error":"no lease.json in lock dir"}"#) {
            LeaseStatus::Degraded(d) => {
                assert!(d.starts_with("legacy-lock"));
                assert!(d.contains("no lease.json"));
            }
            other => panic!("expected Degraded(legacy), got {other:?}"),
        }
        // Corrupt lease.json (exit 18).
        match parse_lease_status(r#"{"present":true,"valid":false,"error":"unparseable heartbeat timestamp"}"#) {
            LeaseStatus::Degraded(d) => assert!(d.starts_with("corrupt-lease")),
            other => panic!("expected Degraded(corrupt), got {other:?}"),
        }
    }

    #[test]
    fn parse_lease_status_degrades_on_garbage() {
        assert!(matches!(parse_lease_status(""), LeaseStatus::Unavailable(_)));
        assert!(matches!(
            parse_lease_status("not json at all"),
            LeaseStatus::Unavailable(_)
        ));
    }

    #[test]
    fn lease_summary_is_human_readable() {
        assert!(LeaseStatus::Absent.summary().contains("свободна"));
        assert!(LeaseStatus::Unavailable("pwsh?".into())
            .summary()
            .contains("недоступен"));
    }

    #[test]
    fn epoch_to_iso8601_matches_known_instants() {
        assert_eq!(epoch_to_iso8601(0), "1970-01-01T00:00:00Z");
        // 2001-09-09T01:46:40Z is the classic 1e9 epoch second.
        assert_eq!(epoch_to_iso8601(1_000_000_000), "2001-09-09T01:46:40Z");
        // A leap-day instant: 2020-02-29T12:00:00Z.
        assert_eq!(epoch_to_iso8601(1_582_977_600), "2020-02-29T12:00:00Z");
    }

    #[test]
    fn now_iso8601_has_the_expected_shape() {
        let s = now_iso8601();
        assert_eq!(s.len(), 20, "YYYY-MM-DDTHH:MM:SSZ is 20 chars: {s}");
        assert!(s.ends_with('Z'));
        assert_eq!(&s[4..5], "-");
        assert_eq!(&s[10..11], "T");
    }
}
