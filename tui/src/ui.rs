//! Render the main overview screen (plan §6.1) from [`AppState`].
//!
//! Layout intent (§6.1): *deviations and actions first, green normal work collapsed*. So the
//! left column leads with an "attention" panel (escalated / conflict / blocked tasks) and only
//! then the compact list of healthy active tasks; the right column shows the recently-completed
//! feed and the human context lifted from `status.md`. The header carries the current
//! batch/cohort, its phase, and the headline counts.
//!
//! This module only reads [`AppState`] and paints frames — no IO, no state mutation.

use ratatui::layout::{Alignment, Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{AppState, CohortPhase, InboxPanel, Modal, RecentKind, Screen, TaskState};
use crate::commands::LeaseStatus;
use crate::inbox::{BlockedCard, DecisionInbox, EscalatedCard, QuarantineCard};

const RED: Color = Color::Red;
const YELLOW: Color = Color::Yellow;
const GREEN: Color = Color::Green;
const CYAN: Color = Color::Cyan;
const DIM: Color = Color::DarkGray;

/// Dispatch to whichever screen is currently active (§6.1 overview / §6.2 Decision Inbox), both
/// switchable from either side with the `Tab` key (see `main.rs`). Command overlays (the
/// lease-status popup and the force-lock confirmation modal) draw on top of the active screen.
pub fn render(f: &mut Frame, app: &AppState) {
    match app.screen {
        Screen::Overview => render_overview(f, app),
        Screen::DecisionInbox => render_decision_inbox(f, app),
    }
    // Overlays, drawn over whichever screen is active. The destructive force-lock modal is drawn
    // last so it sits on top of everything, including an open lease-status popup.
    if let Some(lease) = &app.lease {
        render_lease_overlay(f, lease);
    }
    if app.modal == Modal::ConfirmForceLock {
        render_force_lock_modal(f);
    }
}

fn render_overview(f: &mut Frame, app: &AppState) {
    let root = Layout::vertical([
        Constraint::Length(5), // header (3 content lines inside the border)
        Constraint::Min(3),    // body
        Constraint::Length(1), // footer
    ])
    .split(f.area());

    render_header(f, root[0], app);

    let body =
        Layout::horizontal([Constraint::Percentage(58), Constraint::Percentage(42)]).split(root[1]);
    let left =
        Layout::vertical([Constraint::Percentage(42), Constraint::Percentage(58)]).split(body[0]);
    let right =
        Layout::vertical([Constraint::Percentage(55), Constraint::Percentage(45)]).split(body[1]);

    render_attention(f, left[0], app);
    render_active(f, left[1], app);
    render_recent(f, right[0], app);
    render_context(f, right[1], app);

    render_footer(f, root[2], app);
}

fn block(title: &str) -> Block<'_> {
    Block::default().borders(Borders::ALL).title(Span::styled(
        format!(" {title} "),
        Style::default().add_modifier(Modifier::BOLD),
    ))
}

fn render_header(f: &mut Frame, area: Rect, app: &AppState) {
    let mut lines: Vec<Line> = Vec::new();

    let updated = app.updated_at().unwrap_or_else(|| "—".to_string());
    lines.push(Line::from(vec![
        Span::styled(
            "Оркестр — обзор",
            Style::default().add_modifier(Modifier::BOLD).fg(CYAN),
        ),
        Span::raw("   обновлено: "),
        Span::styled(updated, Style::default().fg(DIM)),
    ]));

    match &app.batch {
        Some(b) => {
            let wave = b.wave.map(|w| w.to_string()).unwrap_or_else(|| "?".into());
            let cap = b
                .max_parallel
                .map(|m| m.to_string())
                .unwrap_or_else(|| "?".into());
            let mut spans = vec![
                Span::raw("Батч "),
                Span::styled(b.batch_id.clone(), Style::default().fg(CYAN)),
                Span::raw("  ·  фаза: "),
                Span::styled(b.phase.label(), Style::default().fg(phase_color(b.phase))),
                Span::raw(format!("  ·  волна {wave}  ·  cap {cap}")),
            ];
            spans.push(Span::styled(
                format!("  ·  открыт {}", short_time(&b.opened_at)),
                Style::default().fg(DIM),
            ));
            if let Some(base) = &b.base {
                let short: String = base.chars().take(8).collect();
                spans.push(Span::styled(
                    format!("  ·  база {short}"),
                    Style::default().fg(DIM),
                ));
            }
            lines.push(Line::from(spans));
        }
        None => lines.push(Line::from(Span::styled(
            "Батч: ждём первое событие cohort.opened…",
            Style::default().fg(DIM),
        ))),
    }

    let active = app.active_tasks().len();
    let attention = app.attention_count();
    let done = app.done_tasks().len();
    let planned = app
        .batch
        .as_ref()
        .map(|b| b.planned_tasks.len())
        .unwrap_or(0);
    lines.push(Line::from(vec![
        Span::styled(format!("активные {active}"), Style::default().fg(GREEN)),
        Span::raw("  ·  "),
        Span::styled(
            format!("требуют внимания {attention}"),
            Style::default().fg(if attention > 0 { RED } else { DIM }),
        ),
        Span::raw("  ·  "),
        Span::raw(format!("завершено {done}")),
        Span::raw("  ·  "),
        Span::raw(format!("в плане {planned}")),
        Span::raw("  ·  "),
        Span::styled(
            format!("событий {}", app.events_seen),
            Style::default().fg(DIM),
        ),
    ]));

    let para =
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(Span::styled(
            " control-plane ",
            Style::default().add_modifier(Modifier::BOLD),
        )));
    f.render_widget(para, area);
}

fn render_attention(f: &mut Frame, area: Rect, app: &AppState) {
    let att = app.attention_tasks();
    let has_attention = !att.is_empty();
    let title = format!("Отклонения / требуют внимания ({})", att.len());
    let mut lines: Vec<Line> = Vec::new();
    if has_attention {
        for t in att {
            lines.push(task_line(app, t, RED));
        }
    } else {
        // Green-normal state collapses to a single dim line with a calm (non-red) border (§6.1).
        lines.push(Line::from(Span::styled(
            "нет отклонений — норма",
            Style::default().fg(DIM),
        )));
    }
    let border_color = if has_attention { RED } else { DIM };
    let para =
        Paragraph::new(lines).block(block(&title).border_style(Style::default().fg(border_color)));
    f.render_widget(para, area);
}

fn render_active(f: &mut Frame, area: Rect, app: &AppState) {
    let active = app.active_tasks();
    let title = format!("Активные задачи ({})", active.len());
    let mut lines: Vec<Line> = Vec::new();
    if active.is_empty() {
        lines.push(Line::from(Span::styled(
            "нет активных задач",
            Style::default().fg(DIM),
        )));
    } else {
        for t in active {
            lines.push(task_line(app, t, GREEN));
        }
    }
    let para = Paragraph::new(lines).block(block(&title));
    f.render_widget(para, area);
}

/// One task row: `T-102  coder_deep  · фаза  — name  (attempts)`.
fn task_line<'a>(app: &AppState, t: &'a TaskState, phase_color: Color) -> Line<'a> {
    let mut spans: Vec<Span> = vec![Span::styled(
        format!("{:<7}", t.task_id),
        Style::default().add_modifier(Modifier::BOLD),
    )];
    if let Some(level) = &t.level {
        spans.push(Span::styled(
            format!("{level:<11}"),
            Style::default().fg(DIM),
        ));
    }
    if let Some(status) = &t.status {
        spans.push(Span::styled(
            format!("· {status}"),
            Style::default().fg(phase_color),
        ));
    }
    if let Some(name) = app.task_name(&t.task_id) {
        spans.push(Span::raw("  — "));
        spans.push(Span::raw(name));
    }
    if t.codex_attempts > 0 {
        spans.push(Span::styled(
            format!("  [codex×{}]", t.codex_attempts),
            Style::default().fg(YELLOW),
        ));
    }
    Line::from(spans)
}

fn render_recent(f: &mut Frame, area: Rect, app: &AppState) {
    let mut lines: Vec<Line> = Vec::new();
    if app.recent.is_empty() {
        lines.push(Line::from(Span::styled(
            "пока ничего не завершено",
            Style::default().fg(DIM),
        )));
    } else {
        for item in &app.recent {
            let color = match item.kind {
                RecentKind::Good => GREEN,
                RecentKind::Attention => RED,
            };
            let mark = match item.kind {
                RecentKind::Good => "✓",
                RecentKind::Attention => "!",
            };
            lines.push(Line::from(vec![
                Span::styled(format!("{mark} "), Style::default().fg(color)),
                Span::styled(short_time(&item.at), Style::default().fg(DIM)),
                Span::raw("  "),
                Span::styled(item.label.clone(), Style::default().fg(color)),
            ]));
        }
    }
    let para = Paragraph::new(lines).block(block("Недавно завершено / события"));
    f.render_widget(para, area);
}

fn render_context(f: &mut Frame, area: Rect, app: &AppState) {
    let mut lines: Vec<Line> = Vec::new();
    match &app.status {
        Some(s) if !s.context_lines.is_empty() => {
            for l in &s.context_lines {
                lines.push(Line::from(Span::raw(l.clone())));
            }
        }
        Some(_) => lines.push(Line::from(Span::styled(
            "status.md без контекстных строк",
            Style::default().fg(DIM),
        ))),
        None => lines.push(Line::from(Span::styled(
            "status.md недоступен — показываю только поток событий",
            Style::default().fg(DIM),
        ))),
    }
    let para = Paragraph::new(lines)
        .block(block("Контекст (status.md)"))
        .wrap(Wrap { trim: true });
    f.render_widget(para, area);
}

fn render_footer(f: &mut Frame, area: Rect, app: &AppState) {
    let inbox_count = app.inbox.card_count();
    let mut spans = vec![
        Span::styled(" q/Esc ", Style::default().fg(CYAN)),
        Span::raw("выход  "),
        Span::styled(" Tab ", Style::default().fg(CYAN)),
        Span::raw("Decision Inbox  "),
        Span::styled(" r ", Style::default().fg(CYAN)),
        Span::raw("status.md  "),
    ];
    spans.extend(command_hint_spans());
    if !app.inbox.is_empty() {
        spans.push(Span::styled(
            format!("   ⚠ требует внимания: {inbox_count}"),
            Style::default().fg(RED),
        ));
    }
    spans.extend(notice_spans(app));
    f.render_widget(
        Paragraph::new(Line::from(spans)).alignment(Alignment::Left),
        area,
    );
}

/// The §5/§6.2 command-key hints shared by both screens' footers: pause / resume / lease-status,
/// and the destructive force-lock (in red — it opens a confirmation modal, `main.rs`).
fn command_hint_spans() -> Vec<Span<'static>> {
    vec![
        Span::styled(" p ", Style::default().fg(CYAN)),
        Span::raw("пауза  "),
        Span::styled(" u ", Style::default().fg(CYAN)),
        Span::raw("снять  "),
        Span::styled(" s ", Style::default().fg(CYAN)),
        Span::raw("аренда  "),
        Span::styled(" x ", Style::default().fg(RED)),
        Span::raw("force-lock"),
    ]
}

/// The trailing footer segment carrying the most recent command's result notice, if any.
fn notice_spans(app: &AppState) -> Vec<Span<'static>> {
    match &app.notice {
        Some(notice) => vec![
            Span::styled("   ⟩ ", Style::default().fg(DIM)),
            Span::styled(notice.clone(), Style::default().fg(YELLOW)),
        ],
        None => Vec::new(),
    }
}

// ---- §6.2 Decision Inbox screen -------------------------------------------------------------
//
// Only rendering: answers to the §6.2 card questions ("what's needed / why can't the agent
// decide / what would this unblock / how urgent") are drawn strictly to the extent they are
// derivable from `AppState::inbox` (built from `engine::state::Snapshot` + `.work/PAUSE`, see
// `main.rs` / `crate::inbox`) — no command is ever sent from here (approve/pause/resume remain a
// later task's mandate).

fn render_decision_inbox(f: &mut Frame, app: &AppState) {
    let root = Layout::vertical([
        Constraint::Length(if app.inbox.paused { 5 } else { 3 }), // header
        Constraint::Min(3),                                       // body
        Constraint::Length(1),                                    // footer
    ])
    .split(f.area());

    render_inbox_header(f, root[0], &app.inbox);
    render_inbox_body(f, root[1], app);
    render_inbox_footer(f, root[2], app);
}

fn render_inbox_header(f: &mut Frame, area: Rect, inbox: &DecisionInbox) {
    let mut lines: Vec<Line> = vec![Line::from(vec![
        Span::styled(
            "Decision Inbox",
            Style::default().add_modifier(Modifier::BOLD).fg(CYAN),
        ),
        Span::raw("   "),
        Span::styled(
            format!("эскалировано {}", inbox.escalated.len()),
            Style::default().fg(if inbox.escalated.is_empty() { DIM } else { RED }),
        ),
        Span::raw("  ·  "),
        Span::styled(
            format!("карантин {}", inbox.quarantined.len()),
            Style::default().fg(if inbox.quarantined.is_empty() {
                DIM
            } else {
                YELLOW
            }),
        ),
        Span::raw("  ·  "),
        Span::styled(
            format!("заблокировано {}", inbox.blocked.len()),
            Style::default().fg(if inbox.blocked.is_empty() {
                DIM
            } else {
                YELLOW
            }),
        ),
    ])];
    if inbox.paused {
        let mut spans = vec![Span::styled(
            "ПАУЗА активна (.work/PAUSE) — конвейер не начнёт новую фазу/раунд",
            Style::default().fg(RED).add_modifier(Modifier::BOLD),
        )];
        if let Some(note) = &inbox.pause_note {
            spans.push(Span::styled(
                format!("  · {note}"),
                Style::default().fg(DIM),
            ));
        }
        lines.push(Line::from(spans));
    }
    let para = Paragraph::new(lines).block(
        Block::default()
            .borders(Borders::ALL)
            .title(Span::styled(
                " control-plane ",
                Style::default().add_modifier(Modifier::BOLD),
            ))
            .border_style(Style::default().fg(if inbox.paused { RED } else { CYAN })),
    );
    f.render_widget(para, area);
}

/// The Decision Inbox body: either the empty-state message (R-1: distinguishes "nothing at all"
/// from "no cards, but paused" — the pause banner in the header still demands attention even
/// with an empty card list) or the three scrollable panels (R-3: each independently focusable
/// with `←`/`→` and scrollable with `↑`/`↓`, so cards beyond the visible height are reachable
/// rather than silently clipped).
fn render_inbox_body(f: &mut Frame, area: Rect, app: &AppState) {
    let inbox = &app.inbox;
    if inbox.card_count() == 0 {
        let message = if inbox.paused {
            "карточек нет, но конвейер на паузе (см. баннер выше) — новая фаза/раунд не начнётся, пока пауза снята"
        } else {
            "ничего не требует решения оператора прямо сейчас"
        };
        let border = if inbox.paused { RED } else { DIM };
        let para = Paragraph::new(Line::from(Span::styled(message, Style::default().fg(DIM))))
            .block(block("Decision Inbox").border_style(Style::default().fg(border)));
        f.render_widget(para, area);
        return;
    }

    let thirds = Layout::vertical([
        Constraint::Percentage(34),
        Constraint::Percentage(33),
        Constraint::Percentage(33),
    ])
    .split(area);

    render_escalated_panel(
        f,
        thirds[0],
        &inbox.escalated,
        app.inbox_focus == InboxPanel::Escalated,
        app.inbox_scroll[InboxPanel::Escalated as usize],
    );
    render_quarantine_panel(
        f,
        thirds[1],
        &inbox.quarantined,
        app.inbox_focus == InboxPanel::Quarantined,
        app.inbox_scroll[InboxPanel::Quarantined as usize],
    );
    render_blocked_panel(
        f,
        thirds[2],
        &inbox.blocked,
        app.inbox_focus == InboxPanel::Blocked,
        app.inbox_scroll[InboxPanel::Blocked as usize],
    );
}

/// `▶ ` prefix on a panel title when it currently holds scroll focus (see `main.rs` for the
/// `←`/`→` key handling that moves it, and `↑`/`↓` for the accompanying `scroll` offset).
fn focus_marker(focused: bool) -> &'static str {
    if focused {
        "▶ "
    } else {
        ""
    }
}

fn render_escalated_panel(
    f: &mut Frame,
    area: Rect,
    cards: &[EscalatedCard],
    focused: bool,
    scroll: u16,
) {
    let mut lines: Vec<Line> = Vec::new();
    if cards.is_empty() {
        lines.push(dim_line("эскалированных задач нет"));
    } else {
        for c in cards {
            lines.push(card_title_line(&c.id, &c.title, RED));
            lines.push(dim_line(
                "  требуется решение оператора — терминальное состояние, само не продолжится",
            ));
            lines.push(field_line(
                "  причина: ",
                c.reason.as_deref().unwrap_or("не указана"),
            ));
            if !c.blocks.is_empty() {
                lines.push(field_line("  разблокирует: ", &c.blocks.join(", ")));
            }
        }
    }
    let title = format!("{}Эскалировано ({})", focus_marker(focused), cards.len());
    let border = if cards.is_empty() { DIM } else { RED };
    let para = Paragraph::new(lines)
        .block(block(&title).border_style(Style::default().fg(border)))
        .wrap(Wrap { trim: true })
        .scroll((scroll, 0));
    f.render_widget(para, area);
}

fn render_quarantine_panel(
    f: &mut Frame,
    area: Rect,
    cards: &[QuarantineCard],
    focused: bool,
    scroll: u16,
) {
    let mut lines: Vec<Line> = Vec::new();
    if cards.is_empty() {
        lines.push(dim_line("нет задач в карантине"));
    } else {
        for c in cards {
            lines.push(card_title_line(&c.id, &c.title, YELLOW));
            let attempt = c
                .attempt
                .map(|a| a.to_string())
                .unwrap_or_else(|| "?".into());
            lines.push(dim_line(&format!(
                "  карантин, попытка {attempt} — вернётся в исполнение автоматически; стоит проверить причину"
            )));
            lines.push(field_line(
                "  причина: ",
                c.reason.as_deref().unwrap_or("не указана"),
            ));
            if !c.blocks.is_empty() {
                lines.push(field_line("  разблокирует: ", &c.blocks.join(", ")));
            }
        }
    }
    let title = format!(
        "{}Карантин / повторы ({})",
        focus_marker(focused),
        cards.len()
    );
    let border = if cards.is_empty() { DIM } else { YELLOW };
    let para = Paragraph::new(lines)
        .block(block(&title).border_style(Style::default().fg(border)))
        .wrap(Wrap { trim: true })
        .scroll((scroll, 0));
    f.render_widget(para, area);
}

fn render_blocked_panel(
    f: &mut Frame,
    area: Rect,
    cards: &[BlockedCard],
    focused: bool,
    scroll: u16,
) {
    let mut lines: Vec<Line> = Vec::new();
    if cards.is_empty() {
        lines.push(dim_line("нет заблокированных задач"));
    } else {
        for c in cards {
            lines.push(card_title_line(&c.id, &c.title, YELLOW));
            if c.blocking_infeasible {
                lines.push(Line::from(vec![
                    Span::styled("  блокировано: ", Style::default().fg(DIM)),
                    Span::styled(
                        format!(
                            "{} эскалирована — без решения по ней не продолжится",
                            c.blocking_on
                        ),
                        Style::default().fg(RED),
                    ),
                ]));
            } else if c.blocking_unknown {
                lines.push(Line::from(vec![
                    Span::styled("  блокировано: ", Style::default().fg(DIM)),
                    Span::styled(
                        format!(
                            "{} не найден ни в очереди, ни в Tasks_Done.md — проверьте Предпосылки:",
                            c.blocking_on
                        ),
                        Style::default().fg(RED),
                    ),
                ]));
            } else {
                lines.push(field_line("  ожидает: ", &c.blocking_on));
            }
        }
    }
    let title = format!("{}Заблокировано ({})", focus_marker(focused), cards.len());
    let border = if cards.is_empty() { DIM } else { YELLOW };
    let para = Paragraph::new(lines)
        .block(block(&title).border_style(Style::default().fg(border)))
        .wrap(Wrap { trim: true })
        .scroll((scroll, 0));
    f.render_widget(para, area);
}

fn render_inbox_footer(f: &mut Frame, area: Rect, app: &AppState) {
    let mut spans = vec![
        Span::styled(" q/Esc ", Style::default().fg(CYAN)),
        Span::raw("выход  "),
        Span::styled(" Tab ", Style::default().fg(CYAN)),
        Span::raw("обзор  "),
        Span::styled(" ←/→ ↑/↓ ", Style::default().fg(CYAN)),
        Span::raw("панели  "),
    ];
    spans.extend(command_hint_spans());
    // Only pause/resume/lease/force-lock are wired; approve/decision actions have no backend yet.
    spans.push(Span::styled(
        "   (approve/решения — не входят)",
        Style::default().fg(DIM),
    ));
    spans.extend(notice_spans(app));
    f.render_widget(
        Paragraph::new(Line::from(spans)).alignment(Alignment::Left),
        area,
    );
}

// ---- command overlays: lease-status popup + force-lock confirmation modal -------------------

/// A centered rectangle `percent_x` × `percent_y` of `area`, for a modal/popup overlay.
fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let vertical = Layout::vertical([
        Constraint::Percentage((100 - percent_y) / 2),
        Constraint::Percentage(percent_y),
        Constraint::Percentage((100 - percent_y) / 2),
    ])
    .split(area);
    Layout::horizontal([
        Constraint::Percentage((100 - percent_x) / 2),
        Constraint::Percentage(percent_x),
        Constraint::Percentage((100 - percent_x) / 2),
    ])
    .split(vertical[1])[1]
}

/// The lease-status popup (§5 lease-status command): who owns `.work/orchestrator.lock` and
/// whether the lease is live, read via the engine crate's owner-checked `state-tx.ps1 status`
/// path (see `commands::query_lease_status`). Dismissed with Esc; refreshed with `s` (`main.rs`).
fn render_lease_overlay(f: &mut Frame, lease: &LeaseStatus) {
    let area = centered_rect(70, 55, f.area());
    f.render_widget(Clear, area);

    let mut lines: Vec<Line> = vec![Line::from(Span::styled(
        lease.summary(),
        Style::default().add_modifier(Modifier::BOLD),
    ))];
    if let LeaseStatus::Present(l) = lease {
        lines.push(Line::from(""));
        lines.push(field_line("  роль: ", l.role.as_deref().unwrap_or("?")));
        lines.push(field_line(
            "  владелец: ",
            l.owner_id.as_deref().unwrap_or("?"),
        ));
        if let Some(host) = &l.host {
            lines.push(field_line("  хост: ", host));
        }
        if let Some(pid) = l.pid {
            lines.push(field_line("  pid: ", &pid.to_string()));
        }
        let liveness = if l.live {
            "жива"
        } else {
            "устарела"
        };
        lines.push(Line::from(vec![
            Span::styled("  состояние: ", Style::default().fg(DIM)),
            Span::styled(
                liveness,
                Style::default().fg(if l.live { GREEN } else { YELLOW }),
            ),
        ]));
        if let Some(reason) = &l.reason {
            lines.push(field_line("  почему: ", reason));
        }
        if let (Some(age), Some(ttl)) = (l.heartbeat_age_secs, l.ttl_seconds) {
            lines.push(field_line("  heartbeat: ", &format!("{age}s / ttl {ttl}s")));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(vec![
        Span::styled(" s ", Style::default().fg(CYAN)),
        Span::raw("обновить   "),
        Span::styled(" Esc ", Style::default().fg(CYAN)),
        Span::raw("закрыть"),
    ]));

    let border = match lease {
        LeaseStatus::Present(l) if l.live => GREEN,
        LeaseStatus::Unavailable(_) | LeaseStatus::Degraded(_) => YELLOW,
        _ => CYAN,
    };
    let para = Paragraph::new(lines)
        .block(block("Аренда orchestrator.lock").border_style(Style::default().fg(border)))
        .wrap(Wrap { trim: true });
    f.render_widget(para, area);
}

/// The force-lock confirmation modal (§6.2 "опасные операции — с явным confirm"): the destructive
/// removal of `.work/orchestrator.lock`, mirroring `cc-processor.sh --force-lock`, only fires on an
/// explicit `y`/Enter here (see `main.rs::handle_modal_key`), never a single stray keystroke.
fn render_force_lock_modal(f: &mut Frame) {
    let area = centered_rect(72, 45, f.area());
    f.render_widget(Clear, area);

    let lines = vec![
        Line::from(Span::styled(
            "Удалить .work/orchestrator.lock (force-lock)?",
            Style::default().fg(RED).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::raw(
            "Разрушительно. Делайте это ТОЛЬКО если предыдущий processor точно не работает —",
        )),
        Line::from(Span::raw(
            "иначе два управляющих цикла столкнутся на одном .work/. Зеркалит",
        )),
        Line::from(Span::raw(
            "cc-processor.sh --force-lock (rm -rf каталога замка целиком).",
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled(" y ", Style::default().fg(RED).add_modifier(Modifier::BOLD)),
            Span::raw("подтвердить удаление    "),
            Span::styled(" n / Esc ", Style::default().fg(CYAN)),
            Span::raw("отмена"),
        ]),
    ];
    let para = Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(Span::styled(
                    " подтверждение force-lock ",
                    Style::default().add_modifier(Modifier::BOLD).fg(RED),
                ))
                .border_style(Style::default().fg(RED)),
        )
        .wrap(Wrap { trim: true });
    f.render_widget(para, area);
}

fn card_title_line<'a>(id: &'a str, title: &'a str, color: Color) -> Line<'a> {
    Line::from(vec![
        Span::styled(
            format!("{id:<7}"),
            Style::default().add_modifier(Modifier::BOLD).fg(color),
        ),
        Span::raw(title),
    ])
}

fn dim_line(text: &str) -> Line<'static> {
    Line::from(Span::styled(text.to_string(), Style::default().fg(DIM)))
}

fn field_line(label: &str, value: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled(label.to_string(), Style::default().fg(DIM)),
        Span::raw(value.to_string()),
    ])
}

fn phase_color(phase: CohortPhase) -> Color {
    match phase {
        CohortPhase::Published | CohortPhase::Closed => GREEN,
        CohortPhase::JoinStarted => YELLOW,
        _ => CYAN,
    }
}

/// Show just the `HH:MM:SS` of an ISO-8601 `occurred_at`, best-effort (falls back to the raw
/// string). Purely cosmetic — no timezone math.
fn short_time(iso: &str) -> String {
    match (iso.find('T'), iso.find('Z')) {
        (Some(t), Some(z)) if z > t + 1 => {
            let time = &iso[t + 1..z];
            // trim optional fractional seconds
            time.split('.').next().unwrap_or(time).to_string()
        }
        _ => iso.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use orchestra_engine::events::parse_line;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    #[test]
    fn short_time_extracts_clock() {
        assert_eq!(short_time("2026-07-11T11:39:48Z"), "11:39:48");
        assert_eq!(short_time("2026-07-11T11:39:48.783Z"), "11:39:48");
        assert_eq!(short_time("garbage"), "garbage");
    }

    /// Render the whole §6.1 screen to an in-memory backend (no real terminal) and assert the
    /// key facts land on screen. This exercises the full layout/paint path headlessly.
    #[test]
    fn renders_main_screen_headlessly() {
        let lines = [
            r#"{"schema_version":1,"event_id":"e1","occurred_at":"2026-07-11T11:46:29Z","type":"cohort.opened","batch_id":"B-9","actor":{"kind":"agent","name":"processor"},"payload":{"base":"abc12345","wave":1,"tasks":["T-77","T-88"],"max_parallel":5}}"#,
            r#"{"schema_version":1,"event_id":"e2","occurred_at":"2026-07-11T11:47:00Z","type":"task.captured","batch_id":"B-9","task_id":"T-77","actor":{"kind":"agent","name":"processor"},"payload":{"level":"coder_deep","branch":"task/T-77","worktree":".work/worktrees/T-77","domain":"tui/**","wave":1}}"#,
            r#"{"schema_version":1,"event_id":"e3","occurred_at":"2026-07-11T11:48:00Z","type":"task.status_changed","batch_id":"B-9","task_id":"T-88","actor":{"kind":"agent","name":"processor"},"payload":{"from":"в работе","to":"эскалирована"}}"#,
        ];
        let mut app = AppState::new();
        for l in lines {
            app.apply(&parse_line(l).unwrap());
        }
        app.status = Some(crate::status::parse(
            "- Обновлено: 2026-07-11T11:48:10Z\n\
- Оркестратор: processor — этап: исполнение когорты\n\
| T-77 | Живой TUI | coder_deep | реализация | task/T-77 | .work/worktrees/T-77 |\n",
        ));

        let backend = TestBackend::new(140, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();

        let buf = terminal.backend().buffer();
        let screen: String = buf.content.iter().map(|c| c.symbol()).collect();

        // header + current batch
        assert!(screen.contains("Оркестр — обзор"), "missing title");
        assert!(screen.contains("B-9"), "missing batch id");
        // deviations-forward: the escalated task and the attention count are visible
        assert!(screen.contains("Отклонения"), "missing attention panel");
        assert!(screen.contains("T-88"), "escalated task not shown");
        assert!(
            screen.contains("эскалирована"),
            "escalation status not shown"
        );
        // active task + its name overlaid from status.md
        assert!(screen.contains("T-77"), "active task not shown");
        assert!(
            screen.contains("Живой TUI"),
            "status.md name overlay missing"
        );
        // recent feed reflects the escalation
        assert!(screen.contains("Недавно завершено"), "missing recent panel");
        // the command-channel key hints are on the footer (pause + the destructive force-lock)
        assert!(
            screen.contains("пауза") && screen.contains("force-lock"),
            "missing command-channel footer hints"
        );
    }

    /// Render the §6.2 Decision Inbox screen headlessly and assert every card category, the
    /// pause banner, and the command-channel footer (with the out-of-scope note) land on screen.
    #[test]
    fn renders_decision_inbox_screen_headlessly() {
        let mut app = AppState::new();
        app.screen = Screen::DecisionInbox;
        app.inbox = DecisionInbox {
            paused: true,
            pause_note: Some("оператор остановил конвейер на ночь".to_string()),
            escalated: vec![crate::inbox::EscalatedCard {
                id: "T-050".to_string(),
                title: "Старая задача".to_string(),
                reason: Some("INTEGRATION_LOOP_MAX".to_string()),
                blocks: vec!["T-060".to_string()],
            }],
            quarantined: vec![crate::inbox::QuarantineCard {
                id: "T-104".to_string(),
                title: "Экран Decision Inbox".to_string(),
                attempt: Some(2),
                reason: Some("merge-conflict".to_string()),
                blocks: vec![],
            }],
            blocked: vec![crate::inbox::BlockedCard {
                id: "T-060".to_string(),
                title: "Ждёт T-050".to_string(),
                blocking_on: "T-050".to_string(),
                blocking_infeasible: true,
                blocking_unknown: false,
            }],
        };

        let backend = TestBackend::new(140, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();

        let buf = terminal.backend().buffer();
        let screen: String = buf.content.iter().map(|c| c.symbol()).collect();

        assert!(screen.contains("Decision Inbox"), "missing screen title");
        assert!(screen.contains("ПАУЗА активна"), "missing pause banner");
        assert!(screen.contains("T-050"), "escalated card not shown");
        assert!(
            screen.contains("INTEGRATION_LOOP_MAX"),
            "escalation reason not shown"
        );
        assert!(screen.contains("T-104"), "quarantine card not shown");
        assert!(
            screen.contains("merge-conflict"),
            "quarantine reason not shown"
        );
        assert!(screen.contains("T-060"), "blocked card not shown");
        assert!(screen.contains("Заблокировано"), "missing blocked panel");
        // the footer now advertises the wired command subset AND that approve/decisions are not.
        assert!(
            screen.contains("force-lock") && screen.contains("approve/решения"),
            "missing command-channel / out-of-scope footer hints"
        );
    }

    #[test]
    fn toggle_screen_switches_between_overview_and_inbox() {
        let mut app = AppState::new();
        assert_eq!(app.screen, Screen::Overview);
        app.toggle_screen();
        assert_eq!(app.screen, Screen::DecisionInbox);
        app.toggle_screen();
        assert_eq!(app.screen, Screen::Overview);
    }

    /// The force-lock confirmation modal overlays the active screen with an explicit destructive
    /// warning and the y/cancel affordances (§6.2 confirm gate) — rendered headlessly.
    #[test]
    fn renders_force_lock_confirm_modal_headlessly() {
        let mut app = AppState::new();
        app.arm_force_lock();

        let backend = TestBackend::new(140, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();
        let buf = terminal.backend().buffer();
        let screen: String = buf.content.iter().map(|c| c.symbol()).collect();

        assert!(
            screen.contains("подтверждение force-lock"),
            "missing modal title"
        );
        assert!(
            screen.contains("orchestrator.lock"),
            "missing lock path in the warning"
        );
        assert!(
            screen.contains("подтвердить") && screen.contains("отмена"),
            "missing confirm/cancel affordances"
        );
    }

    /// The lease-status popup surfaces owner / role / liveness from a `commands::LeaseStatus`.
    #[test]
    fn renders_lease_overlay_headlessly() {
        let mut app = AppState::new();
        app.set_lease(crate::commands::LeaseStatus::Present(
            crate::commands::LeasePresent {
                role: Some("processor".to_string()),
                owner_id: Some("ab12cd34".to_string()),
                host: Some("HOSTA".to_string()),
                pid: Some(4321),
                live: true,
                heartbeat_age_secs: Some(12),
                ttl_seconds: Some(900),
                generation: Some(3),
                reason: Some("pid 4321 alive (start-time matches)".to_string()),
            },
        ));

        let backend = TestBackend::new(140, 40);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| render(f, &app)).unwrap();
        let buf = terminal.backend().buffer();
        let screen: String = buf.content.iter().map(|c| c.symbol()).collect();

        assert!(
            screen.contains("Аренда orchestrator.lock"),
            "missing lease overlay title"
        );
        assert!(screen.contains("ab12cd34"), "missing owner id");
        assert!(screen.contains("processor"), "missing role");
        assert!(screen.contains("жива"), "missing liveness label");
    }
}
