//! Adapter that turns a leaf-agent call into a headless `codex exec` invocation.
//!
//! Spawning `codex exec` from outside Claude Code is ALREADY a solved problem in this
//! repo: `tools/codex-runtime.ps1` builds a safe argv and runs codex as a child process
//! today (the processor invokes THAT wrapper, and codex itself spawns its sandboxed child
//! past the Bash permission gate). So this adapter's only job for the spike is to prove
//! the engine can construct the same fail-closed argv natively. The argv here mirrors
//! `tools/codex-runtime.ps1` `build-argv`:
//!
//!   codex exec -C <worktree> --sandbox <mode> -c approval_policy=never
//!              [--skip-git-repo-check] [-m <model>] -c model_reasoning_effort=<r> -
//!
//! The pinned `-c approval_policy=never` and an explicit `--sandbox` are the fail-closed
//! contract (task T-069): a sandbox-init failure must ERROR, never silently run
//! unsandboxed. The trailing `-` makes codex read the prompt from stdin (never a shell
//! fragment).

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
}

impl CodexCall {
    pub fn new(worktree: impl Into<String>, sandbox: Sandbox) -> Self {
        CodexCall {
            worktree: worktree.into(),
            sandbox,
            model: None,
            reasoning: "medium".into(),
            skip_git_repo_check: false,
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
            // Fail-closed approval policy — pinned literal, never lowered (T-069).
            "-c".into(),
            "approval_policy=never".into(),
        ];
        if self.skip_git_repo_check {
            a.push("--skip-git-repo-check".into());
        }
        if let Some(m) = &self.model {
            a.push("-m".into());
            a.push(m.clone());
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
}
