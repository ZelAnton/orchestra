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
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{AppState, CohortPhase, RecentKind, TaskState};

const RED: Color = Color::Red;
const YELLOW: Color = Color::Yellow;
const GREEN: Color = Color::Green;
const CYAN: Color = Color::Cyan;
const DIM: Color = Color::DarkGray;

pub fn render(f: &mut Frame, app: &AppState) {
    let root = Layout::vertical([
        Constraint::Length(5), // header (3 content lines inside the border)
        Constraint::Min(3),    // body
        Constraint::Length(1), // footer
    ])
    .split(f.area());

    render_header(f, root[0], app);

    let body = Layout::horizontal([Constraint::Percentage(58), Constraint::Percentage(42)])
        .split(root[1]);
    let left = Layout::vertical([Constraint::Percentage(42), Constraint::Percentage(58)])
        .split(body[0]);
    let right = Layout::vertical([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(body[1]);

    render_attention(f, left[0], app);
    render_active(f, left[1], app);
    render_recent(f, right[0], app);
    render_context(f, right[1], app);

    render_footer(f, root[2], app);
}

fn block(title: &str) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
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
        Span::styled(
            format!("активные {active}"),
            Style::default().fg(GREEN),
        ),
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

    let para = Paragraph::new(lines).block(
        Block::default()
            .borders(Borders::ALL)
            .title(Span::styled(
                " control-plane ",
                Style::default().add_modifier(Modifier::BOLD),
            )),
    );
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
    let para = Paragraph::new(lines)
        .block(block(&title).border_style(Style::default().fg(border_color)));
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
        spans.push(Span::styled(format!("{level:<11}"), Style::default().fg(DIM)));
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

fn render_footer(f: &mut Frame, area: Rect, _app: &AppState) {
    let hint = Line::from(vec![
        Span::styled(" q/Esc ", Style::default().fg(CYAN)),
        Span::raw("выход  "),
        Span::styled(" r ", Style::default().fg(CYAN)),
        Span::raw("обновить status.md  "),
        Span::styled(
            " read-only ",
            Style::default().fg(GREEN).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            "— TUI ничего не пишет в .work/",
            Style::default().fg(DIM),
        ),
    ]);
    f.render_widget(Paragraph::new(hint).alignment(Alignment::Left), area);
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
    use orchestra_engine_spike::events::parse_line;
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
        assert!(screen.contains("эскалирована"), "escalation status not shown");
        // active task + its name overlaid from status.md
        assert!(screen.contains("T-77"), "active task not shown");
        assert!(screen.contains("Живой TUI"), "status.md name overlay missing");
        // recent feed reflects the escalation
        assert!(screen.contains("Недавно завершено"), "missing recent panel");
        // read-only assurance is on the footer
        assert!(
            screen.contains("read-only") || screen.contains("ничего не пишет"),
            "missing read-only footer"
        );
    }
}
