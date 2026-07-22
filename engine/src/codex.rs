//! Adapter that turns a leaf-agent call into a headless `codex exec` invocation.
//!
//! Spawning `codex exec` from outside Claude Code is ALREADY a solved problem in this
//! repo: `tools/codex-runtime.ps1` builds a safe argv and runs codex as a child process
//! today (the processor invokes THAT wrapper, and codex itself spawns its sandboxed child
//! past the Bash permission gate). This adapter proves the engine can construct the same
//! fail-closed argv natively, kept in PARITY with
//! `tools/codex-runtime.ps1::Build-CodexArgv` (see `$ROOT/tools/codex-runtime.ps1`,
//! lines ~280-337). The argv here mirrors that function's sandbox/network branches:
//!
//!   codex exec -C <worktree> --sandbox <mode>
//!     [--add-dir <worktree>/.work/codex-cache]                    (read-only only)
//!     [-c sandbox_workspace_write.exclude_slash_tmp=true
//!      -c sandbox_workspace_write.exclude_tmpdir_env_var=true]    (workspace-write on Windows only)
//!     -c approval_policy=never
//!     [--skip-git-repo-check] [-m <model>]
//!     [-c sandbox_workspace_write.network_access=true
//!      -c shell_environment_policy.set={GIT_CONFIG_COUNT="1",...}] (network only)
//!     -c model_reasoning_effort=<r> -
//!
//! The pinned `-c approval_policy=never` and an explicit `--sandbox` are the fail-closed
//! contract (task T-069): a sandbox-init failure must ERROR, never silently run
//! unsandboxed. The read-only `--add-dir` cache exception and the Windows workspace-write
//! `exclude_slash_tmp`/`exclude_tmpdir_env_var` pair are the ENV_LIMIT/sandbox-init-worktree
//! root-cause fix (T-279/K-054): codex's default workspace-write policy grants a SPLIT
//! writable set `[workdir, /tmp, $TMPDIR]` that the native Windows unelevated sandbox cannot
//! enforce; excluding /tmp and $TMPDIR collapses it back to the single `[workdir]` root.
//! The network pair is the T-063 outbound-network + openssl git-TLS override. The trailing
//! `-` makes codex read the prompt from stdin (never a shell fragment).
//!
//! Deliberately NOT mirrored: Build-CodexArgv's caller-side output-capture options
//! (`--json`/EmitJson and `-o`/OutFile) are stdout / thread-id plumbing, not part of the
//! fail-closed sandbox contract, so they stay out of this adapter's argv.

use std::path::Path;

/// Codex sandbox modes accepted by the existing wrapper.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sandbox {
    ReadOnly,
    WorkspaceWrite,
}

impl Sandbox {
    pub fn as_flag(self) -> &'static str {
        match self {
            Sandbox::ReadOnly => "read-only",
            Sandbox::WorkspaceWrite => "workspace-write",
        }
    }
}

pub struct CodexCall {
    pub worktree: String,
    pub sandbox: Sandbox,
    pub model: Option<String>,
    pub reasoning: String,
    pub skip_git_repo_check: bool,
    /// Open the workspace-write sandbox's outbound network and route git TLS through openssl
    /// (T-063). Default `false`; mirrors Build-CodexArgv's `-Network on`. Emitted whenever set,
    /// matching the PS wrapper (which keys the pair purely off `$Network -eq 'on'`).
    pub network: bool,
}

impl CodexCall {
    pub fn new(worktree: impl Into<String>, sandbox: Sandbox) -> Self {
        CodexCall {
            worktree: worktree.into(),
            sandbox,
            model: None,
            reasoning: "medium".into(),
            skip_git_repo_check: false,
            network: false,
        }
    }

    /// Build the argv for `codex` (program name prepended by the caller). The prompt is
    /// delivered on stdin (trailing `-`), matching tools/codex-runtime.ps1.
    pub fn to_argv(&self) -> Vec<String> {
        let mut a: Vec<String> = vec![
            "exec".into(),
            "-C".into(),
            self.worktree.clone(),
            "--sandbox".into(),
            self.sandbox.as_flag().into(),
        ];
        // Sandbox-scoped writable-root shaping, mirroring Build-CodexArgv's
        // `if ($Sandbox -eq 'read-only') { ... } elseif (workspace-write -and OnWindows) { ... }`.
        match self.sandbox {
            Sandbox::ReadOnly => {
                // read-only still needs the narrow internal exception for disposable caches.
                // Path join keeps this cross-platform (not byte-for-byte with PS Join-Path).
                a.push("--add-dir".into());
                a.push(
                    Path::new(&self.worktree)
                        .join(".work/codex-cache")
                        .to_string_lossy()
                        .into_owned(),
                );
            }
            Sandbox::WorkspaceWrite => {
                // ROOT-CAUSE FIX for ENV_LIMIT/sandbox-init-worktree (T-279/K-054). workspace-write
                // already makes the nested `.work/` cache writable, so NO `--add-dir` here: re-adding
                // an already-writable path turns the single-root worktree into the split-root shape
                // the native Windows unelevated sandbox rejects. Instead, Windows-only, drop codex's
                // OWN extra `/tmp`/`$TMPDIR` roots so the writable set collapses to `[workdir]`.
                // POSIX's landlock/seccomp enforces the split fine, so it is left untouched there.
                if cfg!(target_os = "windows") {
                    a.push("-c".into());
                    a.push("sandbox_workspace_write.exclude_slash_tmp=true".into());
                    a.push("-c".into());
                    a.push("sandbox_workspace_write.exclude_tmpdir_env_var=true".into());
                }
            }
        }
        // Fail-closed approval policy — pinned literal, never lowered (T-069).
        a.push("-c".into());
        a.push("approval_policy=never".into());
        if self.skip_git_repo_check {
            a.push("--skip-git-repo-check".into());
        }
        if let Some(m) = &self.model {
            a.push("-m".into());
            a.push(m.clone());
        }
        if self.network {
            // T-063 network overrides: open outbound network in the workspace-write sandbox and
            // route git through the openssl TLS backend. Discrete `-c key=value` pairs (no spaces
            // inside the value), byte-for-byte with Build-CodexArgv's `if ($Network -eq 'on')`.
            a.push("-c".into());
            a.push("sandbox_workspace_write.network_access=true".into());
            a.push("-c".into());
            a.push(
                r#"shell_environment_policy.set={GIT_CONFIG_COUNT="1",GIT_CONFIG_KEY_0="http.sslBackend",GIT_CONFIG_VALUE_0="openssl"}"#
                    .into(),
            );
        }
        a.push("-c".into());
        a.push(format!("model_reasoning_effort={}", self.reasoning));
        a.push("-".into());
        a
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argv_pins_fail_closed_contract() {
        let call = CodexCall {
            worktree: "/abs/wt".into(),
            sandbox: Sandbox::WorkspaceWrite,
            model: Some("gpt-5-codex".into()),
            reasoning: "high".into(),
            skip_git_repo_check: true,
            network: false,
        };
        let argv = call.to_argv();
        assert_eq!(argv[0], "exec");
        assert!(argv.windows(2).any(|w| w[0] == "-C" && w[1] == "/abs/wt"));
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "--sandbox" && w[1] == "workspace-write"));
        // approval_policy=never must be present and pinned.
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "-c" && w[1] == "approval_policy=never"));
        assert!(argv.iter().any(|s| s == "--skip-git-repo-check"));
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "-m" && w[1] == "gpt-5-codex"));
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "-c" && w[1] == "model_reasoning_effort=high"));
        // Prompt comes from stdin.
        assert_eq!(argv.last().map(|s| s.as_str()), Some("-"));
    }

    #[test]
    fn read_only_default_reasoning() {
        let call = CodexCall::new("/w", Sandbox::ReadOnly);
        let argv = call.to_argv();
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "--sandbox" && w[1] == "read-only"));
        assert!(argv
            .windows(2)
            .any(|w| w[0] == "-c" && w[1] == "model_reasoning_effort=medium"));
        assert!(!argv.iter().any(|s| s == "--skip-git-repo-check"));
    }

    #[test]
    fn read_only_adds_codex_cache_add_dir_before_approval() {
        let call = CodexCall::new("/w", Sandbox::ReadOnly);
        let argv = call.to_argv();
        // `--add-dir <worktree>/.work/codex-cache`, mirroring the PS `if ($Sandbox -eq 'read-only')`
        // branch. It sits after `--sandbox read-only` and before the pinned approval policy.
        let add_dir = argv
            .windows(2)
            .position(|w| w[0] == "--add-dir" && w[1].ends_with(".work/codex-cache"))
            .expect("read-only must add the .work/codex-cache writable-cache dir");
        let sandbox = argv
            .windows(2)
            .position(|w| w[0] == "--sandbox" && w[1] == "read-only")
            .unwrap();
        let approval = argv
            .windows(2)
            .position(|w| w[0] == "-c" && w[1] == "approval_policy=never")
            .unwrap();
        assert!(
            sandbox < add_dir && add_dir < approval,
            "--add-dir sits between --sandbox and approval_policy: {argv:?}"
        );
        // The workspace-write-only exclusion pair never appears under read-only.
        assert!(!argv
            .iter()
            .any(|s| s.starts_with("sandbox_workspace_write.exclude")));
    }

    #[test]
    fn workspace_write_shapes_writable_root_per_platform() {
        let call = CodexCall::new("/w", Sandbox::WorkspaceWrite);
        let argv = call.to_argv();
        let sandbox = argv
            .windows(2)
            .position(|w| w[0] == "--sandbox" && w[1] == "workspace-write")
            .unwrap();
        let approval = argv
            .windows(2)
            .position(|w| w[0] == "-c" && w[1] == "approval_policy=never")
            .unwrap();
        let has_slash_tmp = argv
            .windows(2)
            .any(|w| w[0] == "-c" && w[1] == "sandbox_workspace_write.exclude_slash_tmp=true");
        let has_tmpdir = argv
            .windows(2)
            .any(|w| w[0] == "-c" && w[1] == "sandbox_workspace_write.exclude_tmpdir_env_var=true");
        // workspace-write NEVER gets a `--add-dir` cache (would reintroduce the rejected split root).
        assert!(
            !argv.iter().any(|s| s == "--add-dir"),
            "workspace-write must NOT add a --add-dir cache: {argv:?}"
        );
        if cfg!(target_os = "windows") {
            assert!(
                has_slash_tmp && has_tmpdir,
                "Windows workspace-write must exclude the /tmp and $TMPDIR split roots: {argv:?}"
            );
            // The pair comes immediately after `--sandbox workspace-write`, before the approval policy.
            let first = argv
                .windows(2)
                .position(|w| {
                    w[0] == "-c" && w[1] == "sandbox_workspace_write.exclude_slash_tmp=true"
                })
                .unwrap();
            assert_eq!(
                first,
                sandbox + 2,
                "exclude flags come right after --sandbox workspace-write: {argv:?}"
            );
            assert!(first < approval);
        } else {
            assert!(
                !has_slash_tmp && !has_tmpdir,
                "non-Windows workspace-write leaves the split roots untouched: {argv:?}"
            );
        }
    }

    #[test]
    fn network_true_emits_overrides_between_model_and_reasoning() {
        let mut call = CodexCall::new("/w", Sandbox::WorkspaceWrite);
        call.model = Some("gpt-5-codex".into());
        call.network = true;
        let argv = call.to_argv();
        let net_access = argv
            .windows(2)
            .position(|w| w[0] == "-c" && w[1] == "sandbox_workspace_write.network_access=true")
            .expect("network=true must emit the network_access override");
        // The environment-policy value is copied byte-for-byte from the PS T-063 override.
        let env_policy = argv
            .windows(2)
            .position(|w| {
                w[0] == "-c"
                    && w[1]
                        == r#"shell_environment_policy.set={GIT_CONFIG_COUNT="1",GIT_CONFIG_KEY_0="http.sslBackend",GIT_CONFIG_VALUE_0="openssl"}"#
            })
            .expect("network=true must emit the exact openssl git-TLS env-policy override");
        let model = argv
            .windows(2)
            .position(|w| w[0] == "-m" && w[1] == "gpt-5-codex")
            .unwrap();
        let reasoning = argv
            .windows(2)
            .position(|w| w[0] == "-c" && w[1].starts_with("model_reasoning_effort="))
            .unwrap();
        assert!(
            model < net_access && net_access < env_policy && env_policy < reasoning,
            "the network pair sits after -m <model> and before model_reasoning_effort: {argv:?}"
        );
    }

    #[test]
    fn network_false_default_omits_overrides() {
        let call = CodexCall::new("/w", Sandbox::WorkspaceWrite);
        assert!(!call.network, "network defaults to false");
        let argv = call.to_argv();
        assert!(!argv
            .iter()
            .any(|s| s == "sandbox_workspace_write.network_access=true"));
        assert!(!argv
            .iter()
            .any(|s| s.starts_with("shell_environment_policy.set=")));
    }
}
