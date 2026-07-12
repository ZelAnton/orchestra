//! Aggregate the Decision Inbox (plan §6.2) — the main human-in-the-loop screen — from a
//! read-only `engine::state::Snapshot` (T-103) plus the out-of-band `.work/PAUSE` marker.
//!
//! Like [`crate::app`], this module is pure data + a build function and carries no terminal /
//! ratatui dependency: it only *reads* facts already decoded by `Snapshot` (the queue and task
//! descriptors) and never writes a file, takes a lock, or emits an event.
//!
//! Three categories are surfaced, each mapping onto one queue/descriptor fact family:
//!
//! * **Escalated** — queue entries whose status is the terminal `эскалирована · причина=…`
//!   (§13.1): these can never proceed without an operator decision.
//! * **Quarantined** — queue entries re-queued after quarantine (`не начата · попытка=N ·
//!   карантин=…`, §13.1 §3): still `not-started` and will be picked up automatically, but the
//!   repeated failure is worth an operator's eyes.
//! * **Blocked** — plain `не начата` queue entries whose `Предпосылки:` list contains a T-ID that
//!   is not yet resolved, resolved the same way `tools/queue-tx.ps1 ready` does: a predecessor is
//!   "done" if it is `выполнена`/archived, "infeasible" if it is itself `эскалирована`, else still
//!   in flight. A predecessor absent from both `snapshot.queue` and `snapshot.descriptors` is
//!   cross-checked against the caller-supplied `done_ids` (task ids already archived to
//!   `Tasks_Done.md`, decoded by `main.rs::done_task_ids`): confirmed there → resolved; still
//!   absent → surfaced explicitly as `blocking_unknown` rather than silently assumed done, so a
//!   typo'd/stale `Предпосылки:` entry that slipped past `queue-tx.ps1 validate-deps` does not
//!   hide a genuinely blocked task from the operator (R-2).
//!
//! Nothing here invents facts absent from the source Markdown: card fields are `None`/empty when
//! the corresponding suffix (`причина=`, `попытка=`, …) is itself absent from the artifact.

use std::collections::{BTreeMap, BTreeSet};

use orchestra_engine::state::{Snapshot, TaskState};

/// One escalated task — terminal, requires an explicit operator decision (§6.2 Q1/Q2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EscalatedCard {
    pub id: String,
    pub title: String,
    /// The `причина=` suffix, when the escalation carries one.
    pub reason: Option<String>,
    /// Other queue tasks that list this id as a predecessor (§6.2 Q4 "what will unblock").
    pub blocks: Vec<String>,
}

/// One task returned to the queue after quarantine (merge conflict / review rejection / CI …).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuarantineCard {
    pub id: String,
    pub title: String,
    /// The `попытка=` counter, when present.
    pub attempt: Option<u32>,
    /// The `карантин=` reason, when present.
    pub reason: Option<String>,
    /// Other queue tasks that list this id as a predecessor.
    pub blocks: Vec<String>,
}

/// One not-yet-started task whose predecessor is not resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockedCard {
    pub id: String,
    pub title: String,
    /// The concrete unresolved predecessor T-ID (the first one found, in `Предпосылки:` order).
    pub blocking_on: String,
    /// Whether the blocking predecessor is itself escalated — never completes without an
    /// operator decision on THAT task — versus merely still in flight.
    pub blocking_infeasible: bool,
    /// The predecessor id appears in neither `snapshot.queue`, `snapshot.descriptors`, nor
    /// `Tasks_Done.md` — a data-integrity signal (typo'd/stale `Предпосылки:` entry, or a race
    /// with archival) worth the operator's attention, distinct from ordinary in-flight blocking.
    pub blocking_unknown: bool,
}

/// The full Decision Inbox projection (§6.2), built from one `Snapshot` plus the pause marker.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DecisionInbox {
    /// Whether `.work/PAUSE` currently exists.
    pub paused: bool,
    /// The pause marker's own content, if any (informational only — see `agents/processor.md`
    /// "Пауза — kill switch `.work/PAUSE`": only the file's *existence* gates the processor).
    pub pause_note: Option<String>,
    pub escalated: Vec<EscalatedCard>,
    pub quarantined: Vec<QuarantineCard>,
    pub blocked: Vec<BlockedCard>,
}

impl DecisionInbox {
    /// Nothing at all currently needs the operator.
    pub fn is_empty(&self) -> bool {
        !self.paused
            && self.escalated.is_empty()
            && self.quarantined.is_empty()
            && self.blocked.is_empty()
    }

    /// Total number of cards (excludes the pause banner, which is a state, not a card).
    pub fn card_count(&self) -> usize {
        self.escalated.len() + self.quarantined.len() + self.blocked.len()
    }
}

/// Build the Decision Inbox from a snapshot plus whether `.work/PAUSE` currently exists (and its
/// optional note), plus `done_ids` — task ids already archived to `Tasks_Done.md` (decoded by the
/// caller, see `main.rs::done_task_ids`), used only to positively confirm a predecessor absent
/// from the live snapshot is truly done rather than silently assuming it (R-2). Read-only: only
/// reads the already-decoded `snapshot.queue` / `snapshot.descriptors` fields plus the passed-in
/// `done_ids` — no filesystem access happens inside this function.
pub fn build(
    snapshot: &Snapshot,
    paused: bool,
    pause_note: Option<String>,
    done_ids: &BTreeSet<String>,
) -> DecisionInbox {
    // Authoritative state-by-id for predecessor resolution: the descriptor's `Статус:` is
    // authoritative once a task is captured (`engine::state::descriptor`), so it overrides the
    // queue header, which can lag until the processor resyncs it at a phase boundary.
    let mut state_by_id: BTreeMap<&str, TaskState> = BTreeMap::new();
    for q in &snapshot.queue {
        if let Some(st) = q.state {
            state_by_id.insert(q.id.as_str(), st);
        }
    }
    for d in &snapshot.descriptors {
        if let Some(st) = d.state {
            state_by_id.insert(d.id.as_str(), st);
        }
    }

    let mut escalated = Vec::new();
    let mut quarantined = Vec::new();
    let mut blocked = Vec::new();

    for q in &snapshot.queue {
        match q.state {
            Some(TaskState::Escalated) => escalated.push(EscalatedCard {
                id: q.id.clone(),
                title: q.title.clone(),
                reason: q.escalation_reason.clone(),
                blocks: dependents_of(&q.id, snapshot),
            }),
            Some(TaskState::NotStarted) if q.quarantine.is_some() => {
                quarantined.push(QuarantineCard {
                    id: q.id.clone(),
                    title: q.title.clone(),
                    attempt: q.attempt,
                    reason: q.quarantine.clone(),
                    blocks: dependents_of(&q.id, snapshot),
                })
            }
            Some(TaskState::NotStarted) => {
                if let Some((blocking_on, blocking_infeasible, blocking_unknown)) =
                    first_unresolved_prerequisite(&q.prerequisites, &state_by_id, done_ids)
                {
                    blocked.push(BlockedCard {
                        id: q.id.clone(),
                        title: q.title.clone(),
                        blocking_on,
                        blocking_infeasible,
                        blocking_unknown,
                    });
                }
            }
            _ => {}
        }
    }

    DecisionInbox {
        paused,
        pause_note,
        escalated,
        quarantined,
        blocked,
    }
}

/// The first predecessor T-ID that is not yet resolved, whether it is escalated (infeasible
/// without an operator decision on it), and whether it is unresolvable-unknown (absent from the
/// queue, descriptors, AND `done_ids`). `None` if every predecessor is resolved.
fn first_unresolved_prerequisite(
    prerequisites: &[String],
    state_by_id: &BTreeMap<&str, TaskState>,
    done_ids: &BTreeSet<String>,
) -> Option<(String, bool, bool)> {
    for p in prerequisites {
        match state_by_id.get(p.as_str()) {
            Some(TaskState::Done) => continue,
            Some(TaskState::Escalated) => return Some((p.clone(), true, false)),
            Some(_) => return Some((p.clone(), false, false)),
            None => {
                if done_ids.contains(p.as_str()) {
                    // Confirmed archived to Tasks_Done.md -> resolved.
                    continue;
                }
                // Not in queue, descriptors, NOR Tasks_Done.md: surface explicitly (R-2) instead
                // of silently assuming "already done".
                return Some((p.clone(), false, true));
            }
        }
    }
    None
}

/// Other queue tasks that list `id` in their own `Предпосылки:` — i.e. what completing/resolving
/// `id` would help unblock.
fn dependents_of(id: &str, snapshot: &Snapshot) -> Vec<String> {
    snapshot
        .queue
        .iter()
        .filter(|q| q.prerequisites.iter().any(|p| p == id))
        .map(|q| q.id.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use orchestra_engine::state::{Descriptor, IntegrationSnapshot, IntegrationState, QueueEntry};
    use std::path::PathBuf;

    fn queue_entry(
        id: &str,
        title: &str,
        state: Option<TaskState>,
        attempt: Option<u32>,
        quarantine: Option<&str>,
        escalation_reason: Option<&str>,
        prerequisites: &[&str],
    ) -> QueueEntry {
        QueueEntry {
            id: id.to_string(),
            title: title.to_string(),
            state,
            status_literal: String::new(),
            attempt,
            quarantine: quarantine.map(str::to_string),
            escalation_reason: escalation_reason.map(str::to_string),
            prerequisites: prerequisites.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn snapshot(queue: Vec<QueueEntry>, descriptors: Vec<Descriptor>) -> Snapshot {
        Snapshot {
            work_dir: PathBuf::from("/tmp/does-not-matter"),
            queue,
            descriptors,
            cohort: None,
            integration: IntegrationSnapshot {
                state: IntegrationState::None,
                review_sha: None,
                f_cycles: None,
            },
            batch: None,
        }
    }

    #[test]
    fn empty_snapshot_yields_empty_inbox() {
        let snap = snapshot(vec![], vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert!(inbox.is_empty());
        assert_eq!(inbox.card_count(), 0);
    }

    #[test]
    fn escalated_entry_becomes_a_card_with_reason_and_dependents() {
        let q = vec![
            queue_entry(
                "T-050",
                "Старая задача",
                Some(TaskState::Escalated),
                None,
                None,
                Some("INTEGRATION_LOOP_MAX"),
                &[],
            ),
            queue_entry(
                "T-060",
                "Ждёт T-050",
                Some(TaskState::NotStarted),
                None,
                None,
                None,
                &["T-050"],
            ),
        ];
        let snap = snapshot(q, vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert!(!inbox.is_empty());
        assert_eq!(inbox.escalated.len(), 1);
        let card = &inbox.escalated[0];
        assert_eq!(card.id, "T-050");
        assert_eq!(card.reason.as_deref(), Some("INTEGRATION_LOOP_MAX"));
        assert_eq!(card.blocks, vec!["T-060".to_string()]);
        // T-060 is blocked on the escalated (infeasible) T-050.
        assert_eq!(inbox.blocked.len(), 1);
        assert_eq!(inbox.blocked[0].blocking_on, "T-050");
        assert!(inbox.blocked[0].blocking_infeasible);
        assert!(!inbox.blocked[0].blocking_unknown);
    }

    #[test]
    fn quarantined_entry_reads_attempt_and_reason() {
        let q = vec![queue_entry(
            "T-104",
            "Экран Decision Inbox",
            Some(TaskState::NotStarted),
            Some(2),
            Some("merge-conflict"),
            None,
            &["T-102", "T-103"],
        )];
        let snap = snapshot(q, vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert_eq!(inbox.quarantined.len(), 1);
        let card = &inbox.quarantined[0];
        assert_eq!(card.attempt, Some(2));
        assert_eq!(card.reason.as_deref(), Some("merge-conflict"));
        // a quarantined entry is not ALSO counted as merely blocked.
        assert!(inbox.blocked.is_empty());
    }

    #[test]
    fn blocked_entry_waits_on_in_flight_predecessor() {
        let q = vec![
            queue_entry(
                "T-102",
                "TUI экран",
                Some(TaskState::Working),
                None,
                None,
                None,
                &[],
            ),
            queue_entry(
                "T-104",
                "Экран Decision Inbox",
                Some(TaskState::NotStarted),
                None,
                None,
                None,
                &["T-102"],
            ),
        ];
        let snap = snapshot(q, vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert_eq!(inbox.blocked.len(), 1);
        assert_eq!(inbox.blocked[0].blocking_on, "T-102");
        assert!(!inbox.blocked[0].blocking_infeasible);
        assert!(!inbox.blocked[0].blocking_unknown);
    }

    #[test]
    fn predecessor_resolved_via_done_status_unblocks() {
        let q = vec![
            queue_entry(
                "T-101",
                "Основа",
                Some(TaskState::Done),
                None,
                None,
                None,
                &[],
            ),
            queue_entry(
                "T-104",
                "Экран Decision Inbox",
                Some(TaskState::NotStarted),
                None,
                None,
                None,
                &["T-101"],
            ),
        ];
        let snap = snapshot(q, vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert!(inbox.blocked.is_empty());
    }

    #[test]
    fn predecessor_confirmed_done_via_tasks_done_ids_unblocks() {
        // T-050 does not appear in the live snapshot's queue/descriptors, but IS present in the
        // caller-supplied `done_ids` (decoded from Tasks_Done.md) -> confirmed done, so T-104 is
        // NOT reported as blocked on it.
        let q = vec![queue_entry(
            "T-104",
            "Экран Decision Inbox",
            Some(TaskState::NotStarted),
            None,
            None,
            None,
            &["T-050"],
        )];
        let snap = snapshot(q, vec![]);
        let done: BTreeSet<String> = ["T-050".to_string()].into_iter().collect();
        let inbox = build(&snap, false, None, &done);
        assert!(inbox.blocked.is_empty());
    }

    #[test]
    fn predecessor_missing_everywhere_is_surfaced_as_unknown_not_silently_resolved() {
        // T-050 is absent from the queue, descriptors, AND `done_ids` (R-2): rather than
        // silently assuming "already done", it must be surfaced so a typo'd/stale
        // `Предпосылки:` entry doesn't hide a genuinely blocked task from the operator.
        let q = vec![queue_entry(
            "T-104",
            "Экран Decision Inbox",
            Some(TaskState::NotStarted),
            None,
            None,
            None,
            &["T-050"],
        )];
        let snap = snapshot(q, vec![]);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert_eq!(inbox.blocked.len(), 1);
        assert_eq!(inbox.blocked[0].blocking_on, "T-050");
        assert!(inbox.blocked[0].blocking_unknown);
        assert!(!inbox.blocked[0].blocking_infeasible);
    }

    #[test]
    fn descriptor_state_overrides_lagging_queue_header_for_predecessor_resolution() {
        // The queue header still says "в работе" (not yet resynced) but the descriptor already
        // reads "выполнена" -- the descriptor wins, so the dependent is not reported as blocked.
        let q = vec![
            queue_entry(
                "T-101",
                "Основа",
                Some(TaskState::Working),
                None,
                None,
                None,
                &[],
            ),
            queue_entry(
                "T-104",
                "Экран Decision Inbox",
                Some(TaskState::NotStarted),
                None,
                None,
                None,
                &["T-101"],
            ),
        ];
        let d = vec![Descriptor {
            id: "T-101".to_string(),
            state: Some(TaskState::Done),
            status_literal: Some("выполнена".to_string()),
            prerequisites: vec![],
        }];
        let snap = snapshot(q, d);
        let inbox = build(&snap, false, None, &BTreeSet::new());
        assert!(inbox.blocked.is_empty());
    }

    #[test]
    fn pause_marker_is_surfaced_verbatim() {
        let inbox = build(
            &snapshot(vec![], vec![]),
            true,
            Some("2026-07-11T12:00:00Z".into()),
            &BTreeSet::new(),
        );
        assert!(!inbox.is_empty());
        assert!(inbox.paused);
        assert_eq!(inbox.pause_note.as_deref(), Some("2026-07-11T12:00:00Z"));
    }
}
