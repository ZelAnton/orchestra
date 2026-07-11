//! The shared vocabulary the per-task resolvers speak: the executor **level**
//! (`Рекомендуемый исполнитель`), the last-range **author** (`Реализовано:`), and the base
//! Claude **reviewer** tier. These are the typed counterparts of the free-text fields
//! `agents/processor.md` reads out of a `task.md` descriptor.
//!
//! Each type carries a `from_*`/`parse_*` bridge from the Markdown literal to the typed value —
//! pure, allocation-light, `None` on an unrecognized literal — mirroring
//! `contract::Status::parse` and `state::canonical::TaskState::from_markdown`. The resolvers
//! themselves take these typed values, never raw text, so they stay pure transformations.

/// The Claude executor level a task is planned for — planner's `Рекомендуемый исполнитель`
/// field. It keys BOTH the review tier (`tiering`) and the Codex routing gates (`coder`/
/// `reviewer`); the Codex routing never rewrites it (`agents/processor.md`, phases 2.4/2.2/2.8).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    CoderFast,
    Coder,
    CoderDeep,
}

impl Level {
    /// The canonical field token (exactly the literal planner writes).
    pub fn as_str(&self) -> &'static str {
        match self {
            Level::CoderFast => "coder_fast",
            Level::Coder => "coder",
            Level::CoderDeep => "coder_deep",
        }
    }

    /// Map a `Рекомендуемый исполнитель:` literal to its level. Matches the WHOLE trimmed token
    /// (so `coder` never shadows `coder_fast`/`coder_deep`); unrecognized → `None`.
    pub fn from_field(literal: &str) -> Option<Level> {
        Some(match literal.trim() {
            "coder_fast" => Level::CoderFast,
            "coder" => Level::Coder,
            "coder_deep" => Level::CoderDeep,
            _ => return None,
        })
    }
}

/// The author of a committed range — one element of the ordered `Реализовано:` history. The
/// resolvers' independence invariant is stated in these two words: a task's reviewer must be a
/// *different mind* than the author of the range under review (`agents/processor.md`, "Codex-
/// ревьюер и маршрутизация").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImplBy {
    Claude,
    Codex,
}

impl ImplBy {
    /// The canonical token as written into `Реализовано:` (`Claude` primary/fallback, `codex`
    /// only for a Codex-committed range).
    pub fn as_str(&self) -> &'static str {
        match self {
            ImplBy::Claude => "Claude",
            ImplBy::Codex => "codex",
        }
    }

    /// Map one `Реализовано:` token to its author; unrecognized → `None`.
    pub fn parse(token: &str) -> Option<ImplBy> {
        Some(match token.trim() {
            "Claude" => ImplBy::Claude,
            "codex" => ImplBy::Codex,
            _ => return None,
        })
    }
}

/// Parse the ordered `Реализовано:` history (comma-separated, e.g. `Claude, codex, Claude`) into
/// its authors, preserving order and dropping unrecognized tokens. The **last** element is the
/// author of the last-committed range — the one a re-review covers and the one the reviewer
/// resolver must be independent of (`reelect_reviewer`).
pub fn parse_impl_history(value: &str) -> Vec<ImplBy> {
    value.split(',').filter_map(ImplBy::parse).collect()
}

/// The author of the LAST committed range = the last element of the `Реализовано:` history, or
/// `None` for an empty/unrecognized history.
pub fn last_impl(value: &str) -> Option<ImplBy> {
    parse_impl_history(value).last().copied()
}

/// The base Claude reviewer tier chosen by `tiering`: the cheaper sonnet/high `reviewer_std`
/// (for `coder_fast` under `REVIEWER_TIERING`) or the opus/high `reviewer` (everything else).
/// The Codex reviewer routing keys its `full`/`augment` decisions on this base but never
/// changes the tier itself (`agents/processor.md`, phase 2.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaseReviewer {
    ReviewerStd,
    Reviewer,
}

impl BaseReviewer {
    /// The leaf-agent name this tier dispatches to.
    pub fn as_str(&self) -> &'static str {
        match self {
            BaseReviewer::ReviewerStd => "reviewer_std",
            BaseReviewer::Reviewer => "reviewer",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_field_maps_whole_token_only() {
        assert_eq!(Level::from_field("coder_fast"), Some(Level::CoderFast));
        assert_eq!(Level::from_field("  coder  "), Some(Level::Coder));
        assert_eq!(Level::from_field("coder_deep"), Some(Level::CoderDeep));
        // `coder` must not shadow the longer tokens, and vice-versa.
        assert_eq!(Level::from_field("coder_slow"), None);
        assert_eq!(Level::from_field(""), None);
        // Round-trip through the canonical token.
        for l in [Level::CoderFast, Level::Coder, Level::CoderDeep] {
            assert_eq!(Level::from_field(l.as_str()), Some(l));
        }
    }

    #[test]
    fn impl_by_tokens_and_history_order() {
        assert_eq!(ImplBy::parse("Claude"), Some(ImplBy::Claude));
        assert_eq!(ImplBy::parse(" codex "), Some(ImplBy::Codex));
        assert_eq!(ImplBy::parse("gpt"), None);
        // Ordered history: primary + two R-fixes; last element wins.
        let h = parse_impl_history("Claude, codex, Claude");
        assert_eq!(h, vec![ImplBy::Claude, ImplBy::Codex, ImplBy::Claude]);
        assert_eq!(last_impl("Claude, codex, Claude"), Some(ImplBy::Claude));
        assert_eq!(last_impl("Claude, codex"), Some(ImplBy::Codex));
        // Empty / all-unrecognized history has no last author.
        assert_eq!(last_impl(""), None);
        assert_eq!(last_impl("nobody"), None);
        // Unrecognized tokens are dropped, order of the rest preserved.
        assert_eq!(
            parse_impl_history("Claude, ?, codex"),
            vec![ImplBy::Claude, ImplBy::Codex]
        );
    }

    #[test]
    fn base_reviewer_names() {
        assert_eq!(BaseReviewer::ReviewerStd.as_str(), "reviewer_std");
        assert_eq!(BaseReviewer::Reviewer.as_str(), "reviewer");
    }
}
