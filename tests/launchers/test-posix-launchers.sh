#!/usr/bin/env bash
# Hermetic bash coverage for the Claude-backed POSIX launchers. Each launcher runs
# from a disposable directory against fake claude/codex/pwsh binaries, so this test
# never calls a real CLI or creates a consuming project's .work state.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$(mktemp -d)"
MOCK_DIR="$(mktemp -d)"
MISSING_PATH="$(mktemp -d)"
PW_ONLY_DIR="$(mktemp -d)"
ARGS_FILE="$MOCK_DIR/claude-args"
RC_FILE="$MOCK_DIR/claude-rc"
PWSH_ARGS_FILE="$MOCK_DIR/pwsh-args"
FAILURES=0
ROOT_CONFIG_DIR="$RUN_DIR/.orchestra"
ROOT_CONFIG_FILE="$ROOT_CONFIG_DIR/root-config.md"
ORIGINAL_PATH="$PATH"
AWK_PATH="$(command -v awk 2>/dev/null || true)"
mkdir -p "$ROOT_CONFIG_DIR"

cleanup() {
    rm -rf "$RUN_DIR" "$MOCK_DIR" "$MISSING_PATH" "$PW_ONLY_DIR"
}
trap cleanup EXIT

cat > "$MOCK_DIR/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CLAUDE_ARGS_FILE"
printf '%s\n' "${CLAUDE_EXIT_CODE:-0}" > "$CLAUDE_RC_FILE"
exit "${CLAUDE_EXIT_CODE:-0}"
EOF

cat > "$MOCK_DIR/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$MOCK_DIR/pwsh" <<'EOF'
#!/bin/sh
case " $* " in
    *config-runtime.ps1* )
        if [ -n "${PWSH_CONFIG_EXIT_CODE:-}" ]; then exit "$PWSH_CONFIG_EXIT_CODE"; fi
        key=''
        previous=''
        for arg in "$@"; do
            if [ "$previous" = '--key' ]; then key="$arg"; fi
            previous="$arg"
        done
        if [ -f "${ORCHESTRA_HOME:-$HOME/.orchestra}/root-config.md" ]; then
            awk -F: -v wanted="$key" '$1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" { sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]+#.*$/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' "${ORCHESTRA_HOME:-$HOME/.orchestra}/root-config.md"
        fi
        exit 0
        ;;
esac
if [ -n "${PWSH_ARGS_FILE:-}" ]; then printf '%s\n' "$@" > "$PWSH_ARGS_FILE"; fi
if [ -n "${ORCHESTRA_CODEX_ROLE_TOPIC:-}" ]; then
    if [ -n "${PWSH_ARGS_FILE:-}" ]; then printf 'TOPIC=%s\n' "$ORCHESTRA_CODEX_ROLE_TOPIC" >> "$PWSH_ARGS_FILE"; fi
fi
exit 0
EOF
chmod +x "$MOCK_DIR/claude" "$MOCK_DIR/codex" "$MOCK_DIR/pwsh"
if [ -n "$AWK_PATH" ]; then
    printf '#!/bin/sh\nexec %s "$@"\n' "$AWK_PATH" > "$MOCK_DIR/awk"
    chmod +x "$MOCK_DIR/awk"
fi
cp "$MOCK_DIR/pwsh" "$PW_ONLY_DIR/pwsh"
if [ -x "$MOCK_DIR/awk" ]; then cp "$MOCK_DIR/awk" "$PW_ONLY_DIR/awk"; fi
chmod +x "$PW_ONLY_DIR/pwsh"

pass() {
    printf 'Testing %s: [PASS]\n' "$1"
}

fail() {
    printf 'Testing %s: [FAIL] %s\n' "$1" "$2"
    FAILURES=$((FAILURES + 1))
}

contains_argument_pair() {
    local first="$1"
    local second="$2"
    local previous=""
    local current

    while IFS= read -r current; do
        if [ "$previous" = "$first" ] && [ "$current" = "$second" ]; then
            return 0
        fi
        previous="$current"
    done < "$ARGS_FILE"

    return 1
}

clear_root_config() {
    rm -f "$ROOT_CONFIG_FILE"
}

set_root_config() {
    printf '%s\n' "$1" > "$ROOT_CONFIG_FILE"
}

run_with_mock_claude() {
    local launcher="$1"
    local agent="$2"
    local scenario="$3"
    shift 3
    local name="$launcher ($scenario)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local rc

    clear_root_config
    : > "$ARGS_FILE"
    : > "$RC_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" \
            CLAUDE_EXIT_CODE=0 ORCHESTRA_CLAUDE_PERMISSION_MODE=bypassPermissions \
            "$BASH" "$launcher_path" "$@"
    )
    rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc while the mock claude exited 0"
        return
    fi
    if ! contains_argument_pair --agent "$agent"; then
        fail "$name" "captured argv does not contain '--agent $agent'"
        return
    fi
    if ! contains_argument_pair --permission-mode auto; then
        fail "$name" "captured argv does not contain '--permission-mode auto'"
        return
    fi
    if [ "$(cat "$RC_FILE")" != "0" ]; then
        fail "$name" "mock claude exit code was not captured as 0"
        return
    fi

    pass "$name"
}

run_without_claude() {
    local launcher="$1"
    local name="$launcher (missing claude)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local output
    local rc

    set +e
    clear_root_config
    output=$(cd "$RUN_DIR" && PATH="$MISSING_PATH:$PW_ONLY_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" ORCHESTRA_CLAUDE_PERMISSION_MODE= \
        "$BASH" "$launcher_path" 2>&1)
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        fail "$name" "launcher succeeded although claude is absent from PATH"
        return
    fi
    if ! printf '%s\n' "$output" | grep -Eiq 'claude.*(command not found|not found)'; then
        fail "$name" "missing-claude error was unclear: $output"
        return
    fi

    pass "$name"
}

run_with_bypass_permissions() {
    local launcher="$1"
    local agent="$2"
    local name="$launcher (bypassPermissions opt-in)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local rc

    set_root_config 'ORCHESTRA_CLAUDE_PERMISSION_MODE: bypassPermissions'
    : > "$ARGS_FILE"
    : > "$RC_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" \
            CLAUDE_EXIT_CODE=0 ORCHESTRA_CLAUDE_PERMISSION_MODE=unsafe \
            "$BASH" "$launcher_path"
    )
    rc=$?
    if [ "$rc" -ne 0 ] || ! contains_argument_pair --agent "$agent" || \
        ! contains_argument_pair --permission-mode bypassPermissions; then
        fail "$name" "launcher did not forward the validated bypassPermissions mode"
        return
    fi
    pass "$name"
}

run_with_invalid_permission_mode() {
    local launcher="$1"
    local name="$launcher (invalid permission mode)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local output
    local rc

    set_root_config 'ORCHESTRA_CLAUDE_PERMISSION_MODE: unsafe'
    : > "$ARGS_FILE"
    set +e
    output=$(cd "$RUN_DIR" && PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" CLAUDE_ARGS_FILE="$ARGS_FILE" \
        CLAUDE_RC_FILE="$RC_FILE" ORCHESTRA_CLAUDE_PERMISSION_MODE=bypassPermissions \
        "$BASH" "$launcher_path" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 2 ] || [ -s "$ARGS_FILE" ] || \
        ! printf '%s\n' "$output" | grep -Fq 'Invalid ORCHESTRA_CLAUDE_PERMISSION_MODE'; then
        fail "$name" "invalid mode did not fail closed before Claude start (rc=$rc; output=$output)"
        return
    fi
    pass "$name"
}

run_with_config_runtime_failure() {
    local name="cc-enhance.sh (config runtime failure is fail-closed)"
    local launcher_path="$REPO_ROOT/launchers/cc-enhance.sh"
    local output
    local rc

    clear_root_config
    : > "$ARGS_FILE"
    set +e
    output=$(cd "$RUN_DIR" && PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" \
        CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" PWSH_CONFIG_EXIT_CODE=12 \
        "$BASH" "$launcher_path" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 12 ]; then
        fail "$name" "expected exit 12, got $rc: $output"
        return
    fi
    if [ -s "$ARGS_FILE" ]; then
        fail "$name" "Claude started after config resolution failed"
        return
    fi
    pass "$name"
}

run_with_shared_processkit_cli() {
    local name="cc-processor.sh (shared Orchestra ProcessKit CLI discovery)"
    local launcher_path="$REPO_ROOT/launchers/cc-processor.sh"
    local shared_cli="$ROOT_CONFIG_DIR/processkit-cli"
    local rc

    clear_root_config
    printf '#!/bin/sh\nexit 0\n' > "$shared_cli"
    chmod +x "$shared_cli"
    : > "$PWSH_ARGS_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" PWSH_ARGS_FILE="$PWSH_ARGS_FILE" \
            "$BASH" "$launcher_path"
    )
    rc=$?
    rm -f "$shared_cli"
    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc"
        return
    fi
    if ! grep -Eq 'processkit-runtime\.ps1$' "$PWSH_ARGS_FILE" || ! grep -Fxq 'run-root' "$PWSH_ARGS_FILE"; then
        fail "$name" "shared ProcessKit CLI did not activate the ProcessKit root runtime"
        return
    fi
    pass "$name"
}

test_launcher() {
    local launcher="$1"
    local agent="$2"

    run_with_mock_claude "$launcher" "$agent" "no arguments"
    run_with_mock_claude "$launcher" "$agent" "with arguments" --test-argument "two words"
    run_without_claude "$launcher"
    run_with_bypass_permissions "$launcher" "$agent"
    run_with_invalid_permission_mode "$launcher"
}

run_with_mock_codex_processor() {
    local launcher="$1"
    local action="$2"
    shift 2
    local name="$launcher (Codex-native provider, $action)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local rc

    clear_root_config
    : > "$PWSH_ARGS_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" PWSH_ARGS_FILE="$PWSH_ARGS_FILE" ORCHESTRA_PROVIDER=claude \
            "$BASH" "$launcher_path" codex "$@"
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc"
        return
    fi
    if ! grep -Fxq "$action" "$PWSH_ARGS_FILE"; then
        fail "$name" "native runtime action '$action' was not passed to pwsh"
        return
    fi
    if ! grep -Eq 'codex-processor-runtime\.ps1$' "$PWSH_ARGS_FILE"; then
        fail "$name" "codex-processor-runtime.ps1 was not selected"
        return
    fi
    if [ "$action" = "handoff" ]; then
        if ! grep -Fxq -- '-HandoffFrom' "$PWSH_ARGS_FILE" || ! grep -Fxq 'claude' "$PWSH_ARGS_FILE"; then
            fail "$name" "Claude handoff source was not passed to the native runtime"
            return
        fi
        if grep -Fxq -- '--from' "$PWSH_ARGS_FILE"; then
            fail "$name" "launcher-owned --from selector leaked into native runtime arguments"
            return
        fi
    fi
    pass "$name"
}

run_with_mock_codex_role() {
    local launcher="$1"
    local role="$2"
    local name="$launcher (Codex interactive role)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local rc

    clear_root_config
    : > "$PWSH_ARGS_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR:/usr/bin:/bin" ORCHESTRA_HOME="$ROOT_CONFIG_DIR" PWSH_ARGS_FILE="$PWSH_ARGS_FILE" \
            ORCHESTRA_PROVIDER=claude "$BASH" "$launcher_path" codex "opening topic"
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc"
        return
    fi
    if ! grep -Eq 'codex-role-runtime\.ps1$' "$PWSH_ARGS_FILE"; then
        fail "$name" "codex-role-runtime.ps1 was not selected"
        return
    fi
    if ! grep -Fxq -- '-Role' "$PWSH_ARGS_FILE" || ! grep -Fxq "$role" "$PWSH_ARGS_FILE"; then
        fail "$name" "role '$role' was not passed to the Codex runtime"
        return
    fi
    if [ "$role" = 'thinker' ]; then
        if ! grep -Fxq 'TOPIC=opening topic' "$PWSH_ARGS_FILE"; then
            fail "$name" "remaining thinker topic was not forwarded through the safe runtime seam"
            return
        fi
    fi
    pass "$name"
}

test_installed_sync_from_checkout_cwd() {
    local name="cc-sync.sh (installed PATH launcher from checkout cwd)"
    local mirror_dir="$RUN_DIR/mirror"
    local launcher_path="$mirror_dir/cc-sync.sh"
    local expected_runtime="$REPO_ROOT/tools/sync-runtime.ps1"
    local rc

    mkdir -p "$mirror_dir"
    cp "$REPO_ROOT/launchers/cc-sync.sh" "$launcher_path"
    chmod +x "$launcher_path"
    : > "$PWSH_ARGS_FILE"
    (
        cd "$REPO_ROOT" || exit 99
        PATH="$MOCK_DIR:/usr/bin:/bin" PWSH_ARGS_FILE="$PWSH_ARGS_FILE" \
            "$BASH" "$launcher_path" -Quiet
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc"
        return
    fi
    if ! grep -Fxq "$expected_runtime" "$PWSH_ARGS_FILE"; then
        fail "$name" "cwd runtime '$expected_runtime' was not passed to pwsh"
        return
    fi
    if ! grep -Fxq -- '-Quiet' "$PWSH_ARGS_FILE"; then
        fail "$name" "launcher arguments were not forwarded"
        return
    fi

    # A target-local tools/sync-runtime.ps1 without the complete Orchestra
    # identity must not be selected by the installed launcher.
    local target_dir="$RUN_DIR/target-with-stale-tools"
    local output
    mkdir -p "$target_dir/tools"
    printf '%s\n' '# stale target-local fixture' > "$target_dir/tools/sync-runtime.ps1"
    : > "$PWSH_ARGS_FILE"
    output=$(
        cd "$target_dir" || exit 99
        PATH="$MOCK_DIR:/usr/bin:/bin" PWSH_ARGS_FILE="$PWSH_ARGS_FILE" \
            "$BASH" "$launcher_path"
    )
    rc=$?
    if [ "$rc" -ne 0 ] || [ -s "$PWSH_ARGS_FILE" ]; then
        fail "$name" "launcher executed a target-local runtime without full Orchestra identity"
        return
    fi
    if ! printf '%s\n' "$output" | grep -Fq 'no Orchestra checkout found'; then
        fail "$name" "launcher did not report its no-op outside Orchestra"
        return
    fi
    pass "$name"
}

# cc-processor.sh --force-lock routes the operator force-takeover through the single transactional
# path `state-tx.ps1 release --force` when pwsh is available: the mock pwsh records the argv it was
# invoked with, so we assert the launcher no longer does its own raw removal.
run_force_lock_via_state_tx() {
    local name="cc-processor.sh (--force-lock via state-tx release --force)"
    local launcher_path="$REPO_ROOT/launchers/cc-processor.sh"
    local lock_dir="$RUN_DIR/.work/orchestrator.lock"
    local rc

    mkdir -p "$lock_dir"
    printf 'stale\n' > "$lock_dir/lease.json"
    : > "$ARGS_FILE"
    : > "$RC_FILE"
    : > "$PWSH_ARGS_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" \
            PWSH_ARGS_FILE="$PWSH_ARGS_FILE" CLAUDE_EXIT_CODE=0 \
            "$BASH" "$launcher_path" --force-lock
    )
    rc=$?
    rm -rf "$RUN_DIR/.work"
    if [ "$rc" -ne 0 ]; then
        fail "$name" "launcher exited $rc while the mock pwsh/claude exited 0"
        return
    fi
    if ! grep -Eq 'state-tx\.ps1$' "$PWSH_ARGS_FILE"; then
        fail "$name" "state-tx.ps1 was not the 'pwsh -File' target"
        return
    fi
    if ! grep -Fxq 'release' "$PWSH_ARGS_FILE" || ! grep -Fxq -- '--force' "$PWSH_ARGS_FILE"; then
        fail "$name" "state-tx was not invoked as 'release --force'"
        return
    fi
    if ! contains_argument_pair --agent processor; then
        fail "$name" "claude was not launched after the force-release"
        return
    fi
    pass "$name"
}

# When pwsh (PowerShell 7) is not on PATH the same --force-lock must fall back to the raw removal so
# the operator escape hatch still works without PowerShell 7. Uses an isolated PATH (claude + rm,
# but deliberately no pwsh) so the test is independent of whether the host has pwsh installed.
run_force_lock_raw_fallback_without_pwsh() {
    local name="cc-processor.sh (--force-lock raw fallback when pwsh is absent)"
    local launcher_path="$REPO_ROOT/launchers/cc-processor.sh"
    local lock_dir="$RUN_DIR/.work/orchestrator.lock"
    local nopwsh_dir="$MOCK_DIR/nopwsh-bin"
    local rc

    rm -rf "$nopwsh_dir"
    mkdir -p "$nopwsh_dir"
    cp "$MOCK_DIR/claude" "$nopwsh_dir/claude"
    chmod +x "$nopwsh_dir/claude"
    # Provide `rm` as a thin wrapper that execs the real rm by absolute path (rather than copying
    # the binary, which would strip a dynamically-linked rm from its libs). This keeps the isolated
    # PATH free of pwsh while the fallback's `rm -rf` still works on any host.
    printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v rm)" > "$nopwsh_dir/rm"
    chmod +x "$nopwsh_dir/rm"

    mkdir -p "$lock_dir"
    printf 'stale\n' > "$lock_dir/lease.json"
    : > "$ARGS_FILE"
    : > "$RC_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$nopwsh_dir" CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" \
            CLAUDE_EXIT_CODE=0 "$BASH" "$launcher_path" --force-lock
    )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -rf "$RUN_DIR/.work" "$nopwsh_dir"
        fail "$name" "launcher exited $rc while the mock claude exited 0"
        return
    fi
    if [ -d "$lock_dir" ]; then
        rm -rf "$RUN_DIR/.work" "$nopwsh_dir"
        fail "$name" "raw fallback did not remove the lock directory when pwsh was absent"
        return
    fi
    rm -rf "$RUN_DIR/.work" "$nopwsh_dir"
    if ! contains_argument_pair --agent processor; then
        fail "$name" "claude was not launched after the raw fallback"
        return
    fi
    pass "$name"
}

test_launcher cc-audit.sh code_auditor
test_launcher cc-deps.sh dependency_curator
test_launcher cc-enhance.sh enhancement_scout
test_launcher cc-github.sh github_sync
test_launcher cc-inbox.sh inbox_curator
test_launcher cc-processor.sh processor
test_launcher cc-proposal.sh proposal_curator
test_launcher cc-queue.sh queue_builder
test_launcher cc-resume.sh processor
test_launcher cc-thinker.sh thinker
run_with_mock_codex_processor cc-processor.sh start
run_with_config_runtime_failure
run_with_shared_processkit_cli
run_with_mock_codex_processor cc-resume.sh resume
run_with_mock_codex_processor cc-resume.sh handoff --from claude
run_with_mock_codex_role cc-thinker.sh thinker
run_with_mock_codex_role cc-audit.sh code_auditor
run_with_mock_codex_role cc-enhance.sh enhancement_scout
run_force_lock_via_state_tx
run_force_lock_raw_fallback_without_pwsh
test_installed_sync_from_checkout_cwd

if [ "$FAILURES" -ne 0 ]; then
    printf 'POSIX launcher tests failed: %s scenario(s) failed.\n' "$FAILURES"
    exit 1
fi

printf 'POSIX launcher tests passed: all 58 scenarios succeeded.\n'
