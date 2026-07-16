//! Dependency-free UTC timestamp formatting shared by the engine and its consumers.

/// Convert Unix epoch seconds (UTC) to `YYYY-MM-DDTHH:MM:SSZ` at second precision.
///
/// Uses Howard Hinnant's `civil_from_days` algorithm, so callers do not need a calendar
/// dependency. The fixed-width, most-significant-component-first format is also lexically
/// sortable for the timestamps used by the engine's freshness gate.
pub fn epoch_to_iso(secs: u64) -> String {
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
    use super::epoch_to_iso;

    #[test]
    fn epoch_to_iso_formats_known_utc_instants() {
        // Well-known epochs (UTC): 1970-01-01 and 2021-01-01, plus a within-day offset.
        assert_eq!(epoch_to_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso(1_609_459_200), "2021-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso(1_609_462_861), "2021-01-01T01:01:01Z");
    }

    #[test]
    fn epoch_to_iso8601_matches_known_instants() {
        assert_eq!(epoch_to_iso(0), "1970-01-01T00:00:00Z");
        // 2001-09-09T01:46:40Z is the classic 1e9 epoch second.
        assert_eq!(epoch_to_iso(1_000_000_000), "2001-09-09T01:46:40Z");
        // A leap-day instant: 2020-02-29T12:00:00Z.
        assert_eq!(epoch_to_iso(1_582_977_600), "2020-02-29T12:00:00Z");
    }

    #[test]
    fn epoch_to_iso_is_lexically_monotonic_across_boundaries() {
        // The freshness gate compares timestamps lexically, so `+1s` must sort strictly greater —
        // including across a minute rollover (…T00:00:59Z < …T00:01:00Z).
        let boundary = 1_609_459_200 + 59; // 2021-01-01T00:00:59Z
        assert_eq!(epoch_to_iso(boundary), "2021-01-01T00:00:59Z");
        assert_eq!(epoch_to_iso(boundary + 1), "2021-01-01T00:01:00Z");
        assert!(epoch_to_iso(boundary + 1) > epoch_to_iso(boundary));
    }
}
