//! Hermetic, offline proof that `engine lease`'s **DEFAULT** `--script` resolution honours the
//! checkout-vs-mirror identity rule (task T-271, `docs/queue_contract.md` §9). When `--script` is
//! omitted, the engine may use `<root>/tools/state-tx.ps1` **only** if `--root` is a proven
//! Orchestra checkout (all three identity markers `agents/processor.md`,
//! `generate-codex-agents.ps1`, `tools/sync-runtime.ps1`); otherwise it must go to the cc-sync
//! mirror or, absent that, fail with a clean "not found" — never silently execute a foreign/stale
//! target-local `tools/state-tx.ps1`.
//!
//! Every test controls the child's `HOME`/`USERPROFILE` so the real machine's cc-sync mirror can
//! never influence the outcome. The complementary path — an explicit `--script` running the REAL
//! `state-tx.ps1` end to end — stays covered by `lease_fixture.rs`, which this change leaves
//! untouched.

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const BIN: &str = env!("CARGO_BIN_EXE_orchestra-engine");

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A fresh, unique temp directory (removed by the caller at the end of each test).
fn tmp(tag: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "orchestra-lease-default-{tag}-{}-{nanos}-{n}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// The first PowerShell host that can actually launch, or `None` (then a pwsh-gated test self-skips).
fn pwsh_host() -> Option<String> {
    for host in ["pwsh", "powershell"] {
        let ok = Command::new(host)
            .args(["-NoProfile", "-Command", "exit 0"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        if ok {
            return Some(host.to_string());
        }
    }
    None
}

/// Seed all three checkout identity markers under `root` (a proven Orchestra checkout).
fn seed_checkout_markers(root: &std::path::Path) {
    fs::create_dir_all(root.join("agents")).unwrap();
    fs::write(root.join("agents").join("processor.md"), "x").unwrap();
    fs::write(root.join("generate-codex-agents.ps1"), "x").unwrap();
    fs::create_dir_all(root.join("tools")).unwrap();
    fs::write(root.join("tools").join("sync-runtime.ps1"), "x").unwrap();
}

#[test]
fn default_script_refuses_untrusted_target_local_tools() {
    // A non-checkout project (its own/stale `tools/` folder, NO identity markers) carrying a
    // target-local `state-tx.ps1`. If the engine ever executed it, the script drops a sentinel;
    // the correct behaviour is to reject it before any spawn and fail "not found".
    let root = tmp("foreign-root");
    let work = root.join(".work");
    fs::create_dir_all(&work).unwrap();
    let tools = root.join("tools");
    fs::create_dir_all(&tools).unwrap();

    let sentinel = root.join("EXECUTED.marker");
    let stub = format!(
        "Set-Content -LiteralPath '{}' -Value ran\nexit 0\n",
        sentinel.display()
    );
    fs::write(tools.join("state-tx.ps1"), stub).unwrap();

    // Empty HOME/USERPROFILE so no real cc-sync mirror can satisfy resolution either.
    let fake_home = tmp("foreign-home");

    let out = Command::new(BIN)
        .args(["lease", "status", "--work"])
        .arg(&work)
        .arg("--root")
        .arg(&root)
        .env("HOME", &fake_home)
        .env("USERPROFILE", &fake_home)
        .output()
        .expect("spawn engine lease");

    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success(),
        "no trusted state-tx anywhere -> clean failure, never a silent run: {stderr}"
    );
    assert!(
        stderr.contains("not found"),
        "prints the clean not-found diagnostic instead of running the foreign file: {stderr}"
    );
    assert!(
        !sentinel.exists(),
        "the untrusted target-local tools/state-tx.ps1 must never be executed"
    );

    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&fake_home);
}

#[test]
fn default_script_selects_target_local_tools_in_a_proven_checkout() {
    // With all three identity markers under --root, the default DOES resolve to the checkout-local
    // <root>/tools/state-tx.ps1. We don't need a functional state-tx: a stub that drops a sentinel
    // and exits proves the engine SELECTED and ran the checkout copy (a regression check that the
    // marker gate does not lock out a real orchestra checkout). Needs a PowerShell host to observe
    // the spawn; self-skips without one.
    let host = match pwsh_host() {
        Some(h) => h,
        None => {
            eprintln!("SKIP: no PowerShell host (pwsh/powershell) available to observe the spawn");
            return;
        }
    };
    let _ = host;

    let root = tmp("checkout-root");
    let work = root.join(".work");
    fs::create_dir_all(&work).unwrap();
    seed_checkout_markers(&root);

    let sentinel = root.join("EXECUTED.marker");
    let stub = format!(
        "Set-Content -LiteralPath '{}' -Value ran\nWrite-Output 'none (free)'\nexit 0\n",
        sentinel.display()
    );
    fs::write(root.join("tools").join("state-tx.ps1"), stub).unwrap();

    // Empty mirror so this can ONLY resolve via the checkout, not the machine's real mirror.
    let fake_home = tmp("checkout-home");

    let out = Command::new(BIN)
        .args(["lease", "status", "--work"])
        .arg(&work)
        .arg("--root")
        .arg(&root)
        .env("HOME", &fake_home)
        .env("USERPROFILE", &fake_home)
        .output()
        .expect("spawn engine lease");

    assert!(
        sentinel.exists(),
        "a proven checkout's own tools/state-tx.ps1 must be selected and executed (stdout: {}, stderr: {})",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );

    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&fake_home);
}
