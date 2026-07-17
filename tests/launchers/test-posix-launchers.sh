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
ARGS_FILE="$MOCK_DIR/claude-args"
RC_FILE="$MOCK_DIR/claude-rc"
FAILURES=0

cleanup() {
    rm -rf "$RUN_DIR" "$MOCK_DIR" "$MISSING_PATH"
}
trap cleanup EXIT

cat > "$MOCK_DIR/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CLAUDE_ARGS_FILE"
printf '%s\n' "${CLAUDE_EXIT_CODE:-0}" > "$CLAUDE_RC_FILE"
exit "${CLAUDE_EXIT_CODE:-0}"
EOF

for command_name in codex pwsh; do
    cat > "$MOCK_DIR/$command_name" <<'EOF'
#!/bin/sh
exit 0
EOF
done
chmod +x "$MOCK_DIR/claude" "$MOCK_DIR/codex" "$MOCK_DIR/pwsh"

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

run_with_mock_claude() {
    local launcher="$1"
    local agent="$2"
    local scenario="$3"
    shift 3
    local name="$launcher ($scenario)"
    local launcher_path="$REPO_ROOT/launchers/$launcher"
    local rc

    : > "$ARGS_FILE"
    : > "$RC_FILE"
    (
        cd "$RUN_DIR" || exit 99
        PATH="$MOCK_DIR" CLAUDE_ARGS_FILE="$ARGS_FILE" CLAUDE_RC_FILE="$RC_FILE" \
            CLAUDE_EXIT_CODE=0 "$BASH" "$launcher_path" "$@"
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
    output=$(cd "$RUN_DIR" && PATH="$MISSING_PATH" "$BASH" "$launcher_path" 2>&1)
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

test_launcher() {
    local launcher="$1"
    local agent="$2"

    run_with_mock_claude "$launcher" "$agent" "no arguments"
    run_with_mock_claude "$launcher" "$agent" "with arguments" --test-argument "two words"
    run_without_claude "$launcher"
}

test_launcher cc-audit.sh code_auditor
test_launcher cc-enhance.sh enhancement_scout
test_launcher cc-github.sh github_sync
test_launcher cc-processor.sh processor
test_launcher cc-queue.sh queue_builder
test_launcher cc-resume.sh processor
test_launcher cc-thinker.sh thinker

if [ "$FAILURES" -ne 0 ]; then
    printf 'POSIX launcher tests failed: %s scenario(s) failed.\n' "$FAILURES"
    exit 1
fi

printf 'POSIX launcher tests passed: all 21 scenarios succeeded.\n'