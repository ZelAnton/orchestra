//! Small shared, read-only parse helpers for the `state` sources (line fields, id tokens).

/// The value of the first line whose trimmed form starts with `key` (e.g. `"Статус:"`), i.e.
/// the trimmed text after the key. `None` if no such line exists. Used for the single-value
/// Markdown fields (`Статус:`, `Приём:`, `База:`, …).
pub(crate) fn line_field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines()
        .map(str::trim)
        .find_map(|l| l.strip_prefix(key).map(str::trim))
}

/// Parse a comma-separated `Предпосылки:` value into T-ids, dropping empties and any token that
/// is not a T-id (`нет`, dashes, stray words).
pub(crate) fn parse_task_id_list(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|t| is_task_id(t))
        .map(String::from)
        .collect()
}

/// `^T-\d` — a T-id is `T-` followed by at least one digit (mirrors `events::parse`).
pub(crate) fn is_task_id(s: &str) -> bool {
    s.strip_prefix("T-")
        .and_then(|r| r.chars().next())
        .is_some_and(|c| c.is_ascii_digit())
}

/// `^B-\d` — a batch id is `B-` followed by at least one digit (a `B-<UTC-stamp>`).
fn is_batch_id(s: &str) -> bool {
    s.strip_prefix("B-")
        .and_then(|r| r.chars().next())
        .is_some_and(|c| c.is_ascii_digit())
}

/// The first whitespace-delimited `B-<stamp>` token anywhere in `text` (the batch id lives in
/// the leading `# … Batch B-…` / `# Batch B-…` heading of `cohort_state.md` / `batch.md`).
pub(crate) fn find_batch_id(text: &str) -> Option<String> {
    text.split_whitespace()
        .find(|t| is_batch_id(t))
        .map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_field_returns_first_trimmed_match() {
        let text = "# Title\nСтатус: в работе\nПредпосылки: T-101\n";
        assert_eq!(line_field(text, "Статус:"), Some("в работе"));
        assert_eq!(line_field(text, "Предпосылки:"), Some("T-101"));
        assert_eq!(line_field(text, "Отсутствует:"), None);
    }

    #[test]
    fn task_id_list_keeps_only_t_ids() {
        assert_eq!(parse_task_id_list("T-101"), vec!["T-101"]);
        assert_eq!(parse_task_id_list("T-102, T-103"), vec!["T-102", "T-103"]);
        assert!(parse_task_id_list("нет").is_empty());
        assert_eq!(parse_task_id_list("T-1, —, foo"), vec!["T-1"]);
    }

    #[test]
    fn batch_id_found_in_heading() {
        assert_eq!(
            find_batch_id("# Cohort state — Batch B-20260711T113948Z\nПриём: открыт"),
            Some("B-20260711T113948Z".to_string())
        );
        // The integration branch token `integration/B-…` must not be mistaken for the id.
        assert_eq!(find_batch_id("Интеграционная ветка: integration/B-1"), None);
        assert_eq!(find_batch_id("# Когорта\nПриём: закрыт"), None);
    }
}
