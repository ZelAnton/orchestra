//! Fold the `.work/events.jsonl` stream (`cohort.*` / `task.*`) into the display state for the
//! main overview screen (plan §6.1).
//!
//! This module is the *testable core* of the TUI: it is pure data + a fold function and carries
//! no terminal / ratatui dependency, so the aggregation logic can be exercised by unit tests over
//! fixture event lines (the same fixture shape as `engine/tests/events_fixture.rs`) without ever
//! opening a terminal.
//!
//! **Read-only by construction (this module).** Nothing in *this* module writes a file, takes a
//! lock, or emits an event: it only *consumes* the typed [`Event`] values handed over by the engine
//! crate's cursor reader, plus a little UI state (screen, inbox focus, the force-lock confirmation
//! modal, the last command notice). The one place the crate may write is the deliberately narrow
//! §5/§6.2 command channel in [`crate::commands`] (pause / resume / lease-status / force-lock),
//! driven only by an explicit keystroke. The events are the source of truth for the
//! batch/cohort/task projection; `status.md` (see [`crate::status`]) is folded in separately as
//! human context.

use std::collections::BTreeMap;

use orchestra_engine::events::{Event, EventType};
use serde_json::{Map, Value};

use crate::commands::LeaseStatus;
use crate::inbox::DecisionInbox;

/// Which of the two screens (§6.1 overview / §6.2 Decision Inbox) is currently drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Screen {
    #[default]
    Overview,
    DecisionInbox,
}

/// Which Decision Inbox panel currently holds scroll focus (R-3: each of the three panels —
/// escalated/quarantined/blocked — scrolls independently, since a fixed-height layout would
/// otherwise silently clip cards beyond the terminal's height). `←`/`→` in `main.rs` cycle
/// focus; `↑`/`↓` scroll whichever panel is focused. Fieldless, so `as usize` indexes
/// `AppState::inbox_scroll` in declaration order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InboxPanel {
    #[default]
    Escalated,
    Quarantined,
    Blocked,
}

/// A modal overlay that captures input until dismissed. The only modal is the destructive
/// **force-lock** confirmation: force-lock (removing `.work/orchestrator.lock`, mirroring
/// `cc-processor.sh --force-lock`) must never fire from a single stray keystroke, so *arming* it
/// opens this modal and only an explicit *second* confirmation keystroke (see `main.rs`) actually
/// removes the lock (§6.2 "опасные операции — с явным confirm").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Modal {
    #[default]
    None,
    /// Force-lock armed: awaiting the explicit confirm keystroke.
    ConfirmForceLock,
}

/// The stage a task's status maps to, for the "deviations first, green collapsed" §6.1 layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusClass {
    /// A normal in-flight phase (в работе / на ревью / готова к слиянию / слита / опубликована).
    Active,
    /// Requires human attention: escalated / merge-conflict / blocked.
    Attention,
    /// Reached the terminal healthy outcome (выполнена).
    Done,
}

/// Classify a raw descriptor status string (the `payload.to` of a `task.status_changed`).
pub fn classify(status: &str) -> StatusClass {
    let s = status.trim();
    if s.contains("эскалирована") || s.contains("конфликт") || s.contains("блок")
    {
        StatusClass::Attention
    } else if s == "выполнена" {
        StatusClass::Done
    } else {
        StatusClass::Active
    }
}

/// Where a cohort/batch is in its lifecycle, derived from the `cohort.*` family.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CohortPhase {
    Opened,
    RoundStarted,
    RoundClosed,
    AdmissionClosed,
    JoinStarted,
    Published,
    Closed,
}

impl CohortPhase {
    /// A short human label for the header.
    pub fn label(self) -> &'static str {
        match self {
            CohortPhase::Opened => "когорта открыта (приём)",
            CohortPhase::RoundStarted => "волна выполняется",
            CohortPhase::RoundClosed => "волна закрыта",
            CohortPhase::AdmissionClosed => "приём закрыт",
            CohortPhase::JoinStarted => "джойн/интеграция",
            CohortPhase::Published => "опубликована",
            CohortPhase::Closed => "когорта закрыта",
        }
    }
}

/// The current batch/cohort projection.
#[derive(Debug, Clone)]
pub struct BatchState {
    pub batch_id: String,
    pub base: Option<String>,
    pub wave: Option<i64>,
    pub planned_tasks: Vec<String>,
    pub max_parallel: Option<i64>,
    pub phase: CohortPhase,
    pub opened_at: String,
    pub admission_reason: Option<String>,
    pub published_sha: Option<String>,
    pub close_stats: Option<CloseStats>,
}

/// The `cohort.closed` outcome counters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CloseStats {
    pub merged: i64,
    pub quarantined: i64,
    pub escalated: i64,
}

/// One task's projection within the current cohort.
#[derive(Debug, Clone)]
pub struct TaskState {
    pub task_id: String,
    pub batch_id: Option<String>,
    pub level: Option<String>,
    pub branch: Option<String>,
    pub worktree: Option<String>,
    pub domain: Option<String>,
    pub status: Option<String>,
    pub wave: Option<i64>,
    /// Capture order, so the display is stable regardless of `BTreeMap` key ordering.
    pub seq: u64,
    pub last_at: String,
    pub codex_attempts: u32,
}

impl TaskState {
    pub fn class(&self) -> StatusClass {
        match &self.status {
            Some(s) => classify(s),
            None => StatusClass::Active,
        }
    }
}

/// Whether a recent notable transition is a good outcome or something needing attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecentKind {
    Good,
    Attention,
}

/// A recently observed notable fact for the "recently completed / deviations" feed.
#[derive(Debug, Clone)]
pub struct RecentItem {
    pub at: String,
    pub label: String,
    pub kind: RecentKind,
}

const RECENT_CAP: usize = 40;

/// The full display state, folded from the event stream (+ status.md overlay).
#[derive(Debug, Default)]
pub struct AppState {
    pub batch: Option<BatchState>,
    tasks: BTreeMap<String, TaskState>,
    /// Newest-first feed of notable transitions; survives cohort resets, bounded to `RECENT_CAP`.
    pub recent: Vec<RecentItem>,
    /// Overlay parsed from `.work/status.md` (task names, orchestrator context).
    pub status: Option<crate::status::StatusSnapshot>,
    /// Total events consumed (for the header).
    pub events_seen: u64,
    /// `occurred_at` of the most recent event (fallback "updated" when status.md is absent).
    pub last_event_at: Option<String>,
    /// Which screen is currently drawn (§6.1 overview vs §6.2 Decision Inbox).
    pub screen: Screen,
    /// The Decision Inbox projection (§6.2), rebuilt from `engine::state::Snapshot` +
    /// `.work/PAUSE` on the same cadence as the `status.md` overlay (see `main.rs`).
    pub inbox: DecisionInbox,
    /// Which Decision Inbox panel currently holds scroll focus (R-3, see `InboxPanel`).
    pub inbox_focus: InboxPanel,
    /// Per-panel scroll offset (lines), indexed by `InboxPanel as usize` (R-3).
    pub inbox_scroll: [u16; 3],
    /// An open modal overlay capturing input (currently only the force-lock confirmation, §6.2).
    pub modal: Modal,
    /// The most recent lease-status query result (§5 lease-status command), shown as an overlay
    /// until dismissed; `None` before the operator ever queries it.
    pub lease: Option<LeaseStatus>,
    /// A one-line result of the most recent command (pause/resume/force-lock), shown in the footer
    /// as operator feedback; `None` until the first command is issued.
    pub notice: Option<String>,
    next_seq: u64,
}

impl AppState {
    pub fn new() -> AppState {
        AppState::default()
    }

    /// Fold a batch of freshly-polled events (in file order) into the projection.
    pub fn apply_all(&mut self, events: &[Event]) {
        for ev in events {
            self.apply(ev);
        }
    }

    /// Fold one event into the projection.
    pub fn apply(&mut self, ev: &Event) {
        self.events_seen += 1;
        self.last_event_at = Some(ev.occurred_at.clone());
        match ev.event_type {
            EventType::CohortOpened => self.on_cohort_opened(ev),
            EventType::CohortRoundStarted => self.set_phase(CohortPhase::RoundStarted, ev),
            EventType::CohortRoundClosed => self.set_phase(CohortPhase::RoundClosed, ev),
            EventType::CohortAdmissionClosed => {
                self.set_phase(CohortPhase::AdmissionClosed, ev);
                if let Some(b) = self.batch.as_mut() {
                    b.admission_reason = pstr(&ev.payload, "reason");
                }
            }
            EventType::CohortJoinStarted => self.set_phase(CohortPhase::JoinStarted, ev),
            EventType::CohortPublished => self.on_cohort_published(ev),
            EventType::CohortClosed => self.on_cohort_closed(ev),
            EventType::TaskCaptured => self.on_task_captured(ev),
            EventType::TaskStatusChanged => self.on_task_status_changed(ev),
            EventType::CodexAttempt => self.on_codex_attempt(ev),
        }
    }

    fn on_cohort_opened(&mut self, ev: &Event) {
        // A new cohort opening means the previous one is done: reset the per-cohort task view so
        // the screen shows the CURRENT batch. The `recent` feed intentionally survives.
        self.tasks.clear();
        self.next_seq = 0;
        self.batch = Some(BatchState {
            batch_id: ev.batch_id.clone().unwrap_or_default(),
            base: pstr(&ev.payload, "base"),
            wave: pi64(&ev.payload, "wave"),
            planned_tasks: pstrs(&ev.payload, "tasks"),
            max_parallel: pi64(&ev.payload, "max_parallel"),
            phase: CohortPhase::Opened,
            opened_at: ev.occurred_at.clone(),
            admission_reason: None,
            published_sha: None,
            close_stats: None,
        });
    }

    fn on_cohort_published(&mut self, ev: &Event) {
        self.set_phase(CohortPhase::Published, ev);
        if let Some(b) = self.batch.as_mut() {
            b.published_sha = pstr(&ev.payload, "main_sha");
        }
        let ci = pstr(&ev.payload, "ci").unwrap_or_else(|| "?".into());
        let batch = ev.batch_id.clone().unwrap_or_default();
        self.push_recent(
            &ev.occurred_at,
            format!("когорта {batch} опубликована (CI: {ci})"),
            RecentKind::Good,
        );
    }

    fn on_cohort_closed(&mut self, ev: &Event) {
        self.set_phase(CohortPhase::Closed, ev);
        let stats = CloseStats {
            merged: pi64(&ev.payload, "merged").unwrap_or(0),
            quarantined: pi64(&ev.payload, "quarantined").unwrap_or(0),
            escalated: pi64(&ev.payload, "escalated").unwrap_or(0),
        };
        if let Some(b) = self.batch.as_mut() {
            b.close_stats = Some(stats);
        }
        let kind = if stats.quarantined > 0 || stats.escalated > 0 {
            RecentKind::Attention
        } else {
            RecentKind::Good
        };
        let batch = ev.batch_id.clone().unwrap_or_default();
        self.push_recent(
            &ev.occurred_at,
            format!(
                "когорта {batch} закрыта (слито {}, карантин {}, эскалировано {})",
                stats.merged, stats.quarantined, stats.escalated
            ),
            kind,
        );
    }

    fn on_task_captured(&mut self, ev: &Event) {
        let task_id = match &ev.task_id {
            Some(t) => t.clone(),
            None => return,
        };
        let seq = self.alloc_seq();
        let entry = self.task_entry(&task_id, seq, &ev.occurred_at);
        entry.batch_id = ev.batch_id.clone();
        entry.level = pstr(&ev.payload, "level");
        entry.branch = pstr(&ev.payload, "branch");
        entry.worktree = pstr(&ev.payload, "worktree");
        entry.domain = pstr(&ev.payload, "domain");
        entry.wave = pi64(&ev.payload, "wave");
        // A freshly captured task is implicitly "в работе" until its first status change.
        if entry.status.is_none() {
            entry.status = Some("в работе".to_string());
        }
        entry.last_at = ev.occurred_at.clone();
    }

    fn on_task_status_changed(&mut self, ev: &Event) {
        let task_id = match &ev.task_id {
            Some(t) => t.clone(),
            None => return,
        };
        let to = pstr(&ev.payload, "to");
        let seq = self.alloc_seq();
        {
            let entry = self.task_entry(&task_id, seq, &ev.occurred_at);
            if entry.batch_id.is_none() {
                entry.batch_id = ev.batch_id.clone();
            }
            entry.status = to.clone();
            entry.last_at = ev.occurred_at.clone();
        }
        if let Some(to) = to {
            self.maybe_record_transition(ev, &task_id, &to);
        }
    }

    fn on_codex_attempt(&mut self, ev: &Event) {
        if let Some(task_id) = ev.task_id.clone() {
            let seq = self.alloc_seq();
            let entry = self.task_entry(&task_id, seq, &ev.occurred_at);
            entry.codex_attempts += 1;
        }
    }

    fn maybe_record_transition(&mut self, ev: &Event, task_id: &str, to: &str) {
        match classify(to) {
            StatusClass::Attention => self.push_recent(
                &ev.occurred_at,
                format!("{task_id} → {to}"),
                RecentKind::Attention,
            ),
            StatusClass::Done => self.push_recent(
                &ev.occurred_at,
                format!("{task_id} → {to}"),
                RecentKind::Good,
            ),
            StatusClass::Active => {
                // "опубликована" is still active but is a notable positive milestone.
                if to.trim() == "опубликована" {
                    self.push_recent(
                        &ev.occurred_at,
                        format!("{task_id} → {to}"),
                        RecentKind::Good,
                    );
                }
            }
        }
    }

    // ---- small internal helpers ------------------------------------------------------------

    fn alloc_seq(&mut self) -> u64 {
        let s = self.next_seq;
        self.next_seq += 1;
        s
    }

    /// Get or insert a task entry. `seq`/`at` are only used when a new entry is created.
    fn task_entry(&mut self, task_id: &str, seq: u64, at: &str) -> &mut TaskState {
        self.tasks
            .entry(task_id.to_string())
            .or_insert_with(|| TaskState {
                task_id: task_id.to_string(),
                batch_id: None,
                level: None,
                branch: None,
                worktree: None,
                domain: None,
                status: None,
                wave: None,
                seq,
                last_at: at.to_string(),
                codex_attempts: 0,
            })
    }

    fn set_phase(&mut self, phase: CohortPhase, _ev: &Event) {
        if let Some(b) = self.batch.as_mut() {
            b.phase = phase;
        }
    }

    fn push_recent(&mut self, at: &str, label: String, kind: RecentKind) {
        self.recent.insert(
            0,
            RecentItem {
                at: at.to_string(),
                label,
                kind,
            },
        );
        if self.recent.len() > RECENT_CAP {
            self.recent.truncate(RECENT_CAP);
        }
    }

    // ---- read-side accessors for the renderer ---------------------------------------------

    /// Tasks in a given class, in capture order.
    fn tasks_by_class(&self, class: StatusClass) -> Vec<&TaskState> {
        let mut v: Vec<&TaskState> = self.tasks.values().filter(|t| t.class() == class).collect();
        v.sort_by_key(|t| t.seq);
        v
    }

    /// Escalated / conflict / blocked tasks — shown first (§6.1 "deviations forward").
    pub fn attention_tasks(&self) -> Vec<&TaskState> {
        self.tasks_by_class(StatusClass::Attention)
    }

    /// Normal in-flight tasks and their current phase.
    pub fn active_tasks(&self) -> Vec<&TaskState> {
        self.tasks_by_class(StatusClass::Active)
    }

    /// Tasks that reached the terminal healthy outcome within the current cohort.
    pub fn done_tasks(&self) -> Vec<&TaskState> {
        self.tasks_by_class(StatusClass::Done)
    }

    /// Count of tasks needing human attention (the §6.1 "requires human" figure).
    pub fn attention_count(&self) -> usize {
        self.tasks
            .values()
            .filter(|t| t.class() == StatusClass::Attention)
            .count()
    }

    /// Best "updated at": status.md's own timestamp if present, else the last event time.
    pub fn updated_at(&self) -> Option<String> {
        self.status
            .as_ref()
            .and_then(|s| s.updated.clone())
            .or_else(|| self.last_event_at.clone())
    }

    /// Switch between the §6.1 overview and the §6.2 Decision Inbox screen.
    pub fn toggle_screen(&mut self) {
        self.screen = match self.screen {
            Screen::Overview => Screen::DecisionInbox,
            Screen::DecisionInbox => Screen::Overview,
        };
    }

    /// Move Decision Inbox scroll focus to the next panel (R-3; wraps around).
    pub fn focus_next_inbox_panel(&mut self) {
        self.inbox_focus = match self.inbox_focus {
            InboxPanel::Escalated => InboxPanel::Quarantined,
            InboxPanel::Quarantined => InboxPanel::Blocked,
            InboxPanel::Blocked => InboxPanel::Escalated,
        };
    }

    /// Move Decision Inbox scroll focus to the previous panel (R-3; wraps around).
    pub fn focus_prev_inbox_panel(&mut self) {
        self.inbox_focus = match self.inbox_focus {
            InboxPanel::Escalated => InboxPanel::Blocked,
            InboxPanel::Quarantined => InboxPanel::Escalated,
            InboxPanel::Blocked => InboxPanel::Quarantined,
        };
    }

    /// Scroll the currently-focused Decision Inbox panel by `delta` lines (negative scrolls up;
    /// R-3). Saturates at 0 — ratatui itself clips an offset past the content's end, so no upper
    /// clamp is needed here.
    pub fn scroll_inbox(&mut self, delta: i16) {
        let idx = self.inbox_focus as usize;
        let cur = i32::from(self.inbox_scroll[idx]);
        self.inbox_scroll[idx] = (cur + i32::from(delta)).max(0) as u16;
    }

    // ---- command channel state (§5/§6.2 safe command subset) ------------------------------

    /// Arm the destructive force-lock command: open its confirmation modal (step 1). This never
    /// removes the lock by itself — only [`AppState::take_force_lock_confirmation`], after an
    /// explicit second keystroke, does (§6.2).
    pub fn arm_force_lock(&mut self) {
        self.modal = Modal::ConfirmForceLock;
    }

    /// Consume an armed force-lock confirmation (step 2): if the force-lock modal is currently
    /// open, close it and return `true` (the caller should now perform the removal); otherwise
    /// return `false` and do nothing. This is the confirmation *gate* — a `true` result is
    /// impossible without a prior [`AppState::arm_force_lock`], so force-lock can never fire from
    /// one stray keystroke.
    pub fn take_force_lock_confirmation(&mut self) -> bool {
        if self.modal == Modal::ConfirmForceLock {
            self.modal = Modal::None;
            true
        } else {
            false
        }
    }

    /// Dismiss any open modal without acting (Esc / n).
    pub fn dismiss_modal(&mut self) {
        self.modal = Modal::None;
    }

    /// Whether a modal is currently capturing input.
    pub fn has_modal(&self) -> bool {
        self.modal != Modal::None
    }

    /// Record a lease-status query result to show as an overlay.
    pub fn set_lease(&mut self, status: LeaseStatus) {
        self.lease = Some(status);
    }

    /// Dismiss the lease-status overlay. Returns whether one was showing, so the caller can tell
    /// an Esc that consumed the overlay from an Esc that should fall through to quit.
    pub fn dismiss_lease(&mut self) -> bool {
        self.lease.take().is_some()
    }

    /// Friendly display name for a task: status.md's name column if we have it, else the id.
    pub fn task_name(&self, task_id: &str) -> Option<String> {
        self.status
            .as_ref()
            .and_then(|s| s.task_meta.get(task_id))
            .and_then(|m| m.name.clone())
    }
}

// ---- payload extraction helpers (opaque Map<String, Value>) --------------------------------

fn pstr(p: &Map<String, Value>, key: &str) -> Option<String> {
    p.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
}

fn pi64(p: &Map<String, Value>, key: &str) -> Option<i64> {
    p.get(key).and_then(|v| v.as_i64())
}

fn pstrs(p: &Map<String, Value>, key: &str) -> Vec<String> {
    p.get(key)
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use orchestra_engine::events::parse_line;

    /// Decode fixture lines (real `.work/events.jsonl` shape) into typed events, like the reader
    /// would hand them over.
    fn events(lines: &[&str]) -> Vec<Event> {
        lines
            .iter()
            .map(|l| parse_line(l).unwrap_or_else(|e| panic!("fixture line invalid: {e}\n{l}")))
            .collect()
    }

    const OPENED: &str = r#"{"schema_version":1,"event_id":"e-open","occurred_at":"2026-07-11T11:46:29Z","type":"cohort.opened","batch_id":"B-2","actor":{"kind":"agent","name":"processor"},"payload":{"base":"deadbeef","wave":1,"tasks":["T-10","T-11"],"max_parallel":5}}"#;
    const CAP_10: &str = r#"{"schema_version":1,"event_id":"e-c10","occurred_at":"2026-07-11T11:46:59Z","type":"task.captured","batch_id":"B-2","task_id":"T-10","actor":{"kind":"agent","name":"processor"},"payload":{"level":"coder_deep","branch":"task/T-10","worktree":".work/worktrees/T-10","domain":"tui/**","wave":1}}"#;
    const CAP_11: &str = r#"{"schema_version":1,"event_id":"e-c11","occurred_at":"2026-07-11T11:47:01Z","type":"task.captured","batch_id":"B-2","task_id":"T-11","actor":{"kind":"agent","name":"processor"},"payload":{"level":"coder","branch":"task/T-11","worktree":".work/worktrees/T-11","domain":"engine/**","wave":1}}"#;
    const REVIEW_10: &str = r#"{"schema_version":1,"event_id":"e-r10","occurred_at":"2026-07-11T12:00:12Z","type":"task.status_changed","batch_id":"B-2","task_id":"T-10","actor":{"kind":"agent","name":"processor"},"payload":{"from":"в работе","to":"на ревью"}}"#;

    #[test]
    fn cohort_opened_sets_current_batch() {
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED]));
        let b = app.batch.as_ref().expect("batch set");
        assert_eq!(b.batch_id, "B-2");
        assert_eq!(b.wave, Some(1));
        assert_eq!(b.max_parallel, Some(5));
        assert_eq!(b.planned_tasks, vec!["T-10", "T-11"]);
        assert_eq!(b.phase, CohortPhase::Opened);
        assert_eq!(app.events_seen, 1);
    }

    #[test]
    fn captured_tasks_start_active_in_capture_order() {
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, CAP_11, CAP_10]));
        let active = app.active_tasks();
        let ids: Vec<&str> = active.iter().map(|t| t.task_id.as_str()).collect();
        // capture order (T-11 then T-10), not BTreeMap key order.
        assert_eq!(ids, ["T-11", "T-10"]);
        assert_eq!(active[0].status.as_deref(), Some("в работе"));
        assert_eq!(active[0].level.as_deref(), Some("coder"));
        assert_eq!(app.attention_count(), 0);
    }

    #[test]
    fn status_change_updates_phase() {
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, CAP_10, REVIEW_10]));
        let t = app
            .active_tasks()
            .into_iter()
            .find(|t| t.task_id == "T-10")
            .expect("T-10 active");
        assert_eq!(t.status.as_deref(), Some("на ревью"));
        assert_eq!(t.class(), StatusClass::Active);
    }

    #[test]
    fn escalation_moves_task_to_attention_and_recent() {
        let esc = r#"{"schema_version":1,"event_id":"e-esc","occurred_at":"2026-07-11T12:05:00Z","type":"task.status_changed","batch_id":"B-2","task_id":"T-11","actor":{"kind":"agent","name":"processor"},"payload":{"from":"в работе","to":"эскалирована"}}"#;
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, CAP_10, CAP_11, esc]));
        assert_eq!(app.attention_count(), 1);
        let att = app.attention_tasks();
        assert_eq!(att.len(), 1);
        assert_eq!(att[0].task_id, "T-11");
        // active list no longer contains the escalated task.
        assert!(app.active_tasks().iter().all(|t| t.task_id != "T-11"));
        // and it shows up in the recent feed as an attention item, newest-first.
        assert_eq!(
            app.recent.first().map(|r| r.kind),
            Some(RecentKind::Attention)
        );
        assert!(app.recent[0].label.contains("T-11"));
    }

    #[test]
    fn published_and_done_land_in_recent_feed() {
        let done = r#"{"schema_version":1,"event_id":"e-done","occurred_at":"2026-07-11T12:10:00Z","type":"task.status_changed","batch_id":"B-2","task_id":"T-10","actor":{"kind":"agent","name":"processor"},"payload":{"from":"опубликована","to":"выполнена"}}"#;
        let published = r#"{"schema_version":1,"event_id":"e-pub","occurred_at":"2026-07-11T12:20:00Z","type":"cohort.published","batch_id":"B-2","actor":{"kind":"agent","name":"processor"},"payload":{"main_sha":"cafef00d","pushed":true,"tasks":["T-10","T-11"],"ci":"confirmed"}}"#;
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, CAP_10, done, published]));
        assert_eq!(app.batch.as_ref().unwrap().phase, CohortPhase::Published);
        assert_eq!(
            app.batch.as_ref().unwrap().published_sha.as_deref(),
            Some("cafef00d")
        );
        assert_eq!(app.done_tasks().len(), 1);
        // recent, newest-first: cohort published, then the done transition.
        assert!(app.recent[0].label.contains("опубликована"));
        assert!(app.recent[0].label.contains("B-2"));
        assert!(app
            .recent
            .iter()
            .any(|r| r.label.contains("T-10 → выполнена")));
        assert!(app.recent.iter().all(|r| r.kind == RecentKind::Good));
    }

    #[test]
    fn cohort_closed_records_stats_and_flags_quarantine() {
        let closed = r#"{"schema_version":1,"event_id":"e-cl","occurred_at":"2026-07-11T12:30:00Z","type":"cohort.closed","batch_id":"B-2","actor":{"kind":"agent","name":"processor"},"payload":{"merged":1,"quarantined":1,"escalated":0}}"#;
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, closed]));
        let stats = app.batch.as_ref().unwrap().close_stats.unwrap();
        assert_eq!(stats.merged, 1);
        assert_eq!(stats.quarantined, 1);
        // quarantine > 0 => the close is flagged as an attention item, not silent-green.
        assert_eq!(app.recent[0].kind, RecentKind::Attention);
    }

    #[test]
    fn new_cohort_opening_resets_task_view_but_keeps_recent() {
        let opened2 = r#"{"schema_version":1,"event_id":"e-open2","occurred_at":"2026-07-11T13:00:00Z","type":"cohort.opened","batch_id":"B-3","actor":{"kind":"agent","name":"processor"},"payload":{"base":"beefcafe","wave":1,"tasks":["T-20"],"max_parallel":5}}"#;
        let done = r#"{"schema_version":1,"event_id":"e-done","occurred_at":"2026-07-11T12:10:00Z","type":"task.status_changed","batch_id":"B-2","task_id":"T-10","actor":{"kind":"agent","name":"processor"},"payload":{"from":"опубликована","to":"выполнена"}}"#;
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, CAP_10, done, opened2]));
        // the projection now reflects the NEW cohort; T-10 no longer shown.
        assert_eq!(app.batch.as_ref().unwrap().batch_id, "B-3");
        assert!(app.active_tasks().is_empty());
        assert!(app.done_tasks().is_empty());
        // but the recent feed retains the T-10 completion.
        assert!(app
            .recent
            .iter()
            .any(|r| r.label.contains("T-10 → выполнена")));
    }

    #[test]
    fn codex_attempts_counted_even_before_capture() {
        let attempt = r#"{"schema_version":1,"event_id":"e-at","occurred_at":"2026-07-11T11:50:00Z","type":"codex.attempt","batch_id":"B-2","task_id":"T-10","actor":{"kind":"tool","name":"codex"},"payload":{"role":"coder","attempt_number":1}}"#;
        let mut app = AppState::new();
        app.apply_all(&events(&[OPENED, attempt, CAP_10]));
        let t = app
            .active_tasks()
            .into_iter()
            .find(|t| t.task_id == "T-10")
            .unwrap();
        assert_eq!(t.codex_attempts, 1);
        // capture after the attempt still fills in the metadata.
        assert_eq!(t.level.as_deref(), Some("coder_deep"));
    }

    #[test]
    fn inbox_panel_focus_cycles_and_wraps() {
        let mut app = AppState::new();
        assert_eq!(app.inbox_focus, InboxPanel::Escalated);
        app.focus_next_inbox_panel();
        assert_eq!(app.inbox_focus, InboxPanel::Quarantined);
        app.focus_next_inbox_panel();
        assert_eq!(app.inbox_focus, InboxPanel::Blocked);
        app.focus_next_inbox_panel();
        assert_eq!(app.inbox_focus, InboxPanel::Escalated);
        app.focus_prev_inbox_panel();
        assert_eq!(app.inbox_focus, InboxPanel::Blocked);
    }

    #[test]
    fn inbox_scroll_is_per_panel_and_saturates_at_zero() {
        let mut app = AppState::new();
        app.scroll_inbox(5);
        assert_eq!(app.inbox_scroll[InboxPanel::Escalated as usize], 5);
        app.focus_next_inbox_panel();
        app.scroll_inbox(3);
        assert_eq!(app.inbox_scroll[InboxPanel::Quarantined as usize], 3);
        // the other panel's offset is untouched.
        assert_eq!(app.inbox_scroll[InboxPanel::Escalated as usize], 5);
        // scrolling up past 0 saturates instead of underflowing.
        app.scroll_inbox(-100);
        assert_eq!(app.inbox_scroll[InboxPanel::Quarantined as usize], 0);
    }

    #[test]
    fn force_lock_needs_arming_then_explicit_confirmation() {
        let mut app = AppState::new();
        // No modal by default; a bare confirmation does NOT fire — force-lock can never happen
        // from a single stray keystroke (§6.2 "не одно случайное нажатие").
        assert!(!app.has_modal());
        assert!(!app.take_force_lock_confirmation());
        // Arming opens the modal but still removes nothing.
        app.arm_force_lock();
        assert!(app.has_modal());
        assert_eq!(app.modal, Modal::ConfirmForceLock);
        // The explicit second confirmation fires exactly once and closes the modal.
        assert!(app.take_force_lock_confirmation());
        assert!(!app.has_modal());
        // A repeat confirmation after the modal closed does nothing.
        assert!(!app.take_force_lock_confirmation());
    }

    #[test]
    fn force_lock_modal_can_be_cancelled_without_firing() {
        let mut app = AppState::new();
        app.arm_force_lock();
        assert!(app.has_modal());
        app.dismiss_modal();
        assert!(!app.has_modal());
        // After cancelling, a later confirmation attempt does not fire.
        assert!(!app.take_force_lock_confirmation());
    }

    #[test]
    fn lease_overlay_set_and_dismiss() {
        let mut app = AppState::new();
        assert!(app.lease.is_none());
        // Dismissing when nothing is showing reports "nothing consumed".
        assert!(!app.dismiss_lease());
        app.set_lease(crate::commands::LeaseStatus::Absent);
        assert!(app.lease.is_some());
        assert!(app.dismiss_lease());
        assert!(app.lease.is_none());
    }

    #[test]
    fn classify_buckets() {
        assert_eq!(classify("в работе"), StatusClass::Active);
        assert_eq!(classify("на ревью"), StatusClass::Active);
        assert_eq!(classify("готова к слиянию"), StatusClass::Active);
        assert_eq!(classify("опубликована"), StatusClass::Active);
        assert_eq!(classify("выполнена"), StatusClass::Done);
        assert_eq!(classify("эскалирована"), StatusClass::Attention);
        assert_eq!(classify("конфликт"), StatusClass::Attention);
    }
}
