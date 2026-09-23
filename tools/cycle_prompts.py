"""Fixed sequential profile; deliberately independent of generated queue roles."""

PROFILES = {
    "coordinate": ("codex", "gpt-5.6-luna", "xhigh"),
    "code": ("claude", "claude-fable-5-1", "high"),
    "sol": ("codex", "gpt-6-sol", "xhigh"),
    "astra": ("codex", "gpt-6-astra", "xhigh"),
    "claude": ("claude", "opus", "xhigh"),
    "publish": ("codex", "gpt-5.6-luna", "high"),
    "heal": ("codex", "gpt-6-astra", "xhigh"),
}

REVIEW_ROLES = ("sol", "claude", "astra")
REVIEW_TARGETS = {"sol": 3, "claude": 2, "astra": 1}
REVIEW_PROFILE_VERSION = 2

PROMPTS = {
    "code": "делай следующую стадию. Не запускай ревью, не пушь",
    "sol": """Claude реализовал следующий этап

%%DESCRIPTION%%

Проводи ревью, исправляй, повторяй до тех пор пока в последних 3 проходах не будет ошибок. После 3-его прохода учитывай только ошибки имплементации, исправления комментариев, документации исправляй но не
учитывай

не пушь""",
    "claude": """проводи ревью, исправляй, повторяй в цикле пока в последних двух проходах не будет сделано ни одного исправления имплементации""",
    "astra": """Проводи третье, финальное ревью всей текущей стадии после Sol и Opus.
Исправляй найденные ошибки и проверяй изменения. Требуется один чистый полный проход
без исправлений реализации и других существенных дефектов; мелкие правки оформления
не сбрасывают чистый проход. Выполни только один проход в этом вызове: цикл ведёт runtime.
Существенные изменения реализации требуют возврата к Sol и повторения всех трёх ревью.
Не пушь.""",
    "publish": """Prepare the reviewed stage for runtime publication. Inspect the supplied exact
stage_paths and current Git state read-only. Return done when ready, with summary
as a concise imperative commit subject suitable for the affected repositories;
omit task identifiers. The runtime will perform staging, commit and push after
validating your report. Do not run git add, commit, push, reset or modify files.
Do not claim publication occurred when you only prepared it.""",
    "coordinate": """Coordinate the sequential main-branch workflow using the supplied concise
outcome and artifact paths. Do not implement, review, run another provider, modify
files, commit or push. Confirm the proposed phase, or report a concrete blocker.
The code phase may be recovery of an already implemented stage's lost or rejected
final report. Confirm that report-finalization route without doing it yourself;
do not require another implementation stage or claim that reviews were performed.
Only report complete when the supplied stage source is exhausted and there is no
unfinished implementation or publication. Do not re-read full transcripts unless
the concise outcome is insufficient to make a decision.""",
    "heal": """You are the separate Astra/xhigh recovery agent, independent of the coding
and review roles. Resolve the supplied blocker within the existing task and authority.
Read the interrupted invocation's artifacts, verify its diagnosis, choose and try
safe repairs, and verify the result. A request for human intervention in an earlier
report is a claim to investigate, not proof that the operator must act.
Use existing operator authorization before asking for more. Routine engineering
choices and necessary prerequisites inside the authorized task, including listed
member repositories, are recovery work; complete them instead of merely proposing
that the operator authorize them. Changes to product authentication/authorization
code are distinct from changing your own execution permissions or account access.
Preserve protected paths and unrelated work; project membership does not remove
those guards or authorize changes outside the current task.
Return done only after verifying the repair. If attempts fail, or an indispensable
step actually requires the human (for example payment, interactive login, a missing
secret, consent or authority the operator has not granted), return blocked. Evidence
must state what was checked/tried, why available authorized alternatives cannot
resolve it, and the exact remaining human action. Cite the specific rule or refusal
when authorization is missing; do not infer a need for permission from a filename
or the presence of another member repository.
Do not commit, push, reset or discard work, bypass a refusal, approve on behalf of
the operator, change runtime/account credentials or execution permissions, delete
locks, or start another provider. Implementation fixes must return through all three
reviews. Do not broaden the task to unrelated projects.""",
}

CONTRACT = """This is the operator-selected cc-focus profile, not the queue processor.
Ignore Orchestra's default model, effort, parallelism, worktree and review-loop
settings. Preserve project coding and safety rules. Work only in the existing
main checkout, or in the member main checkouts listed in the project context.
A project iteration may change several member repositories; review the entire
combined change, then publish only the listed publication targets independently.
Files outside the listed repositories are read-only context. Never create a Git
repository at the project root. Do not create branches, worktrees, subagents, parallel tasks or
background jobs, or invoke Claude/Codex recursively.
Run builds and tests synchronously, one tool call at a time. In Claude, Bash has
a 30-minute default timeout and permits up to 21600000 ms (six hours) for a long
command; request an adequate timeout explicitly. The outer invocation still has
its six-hour deadline. Do not use Monitor, cron, workflow or wakeup tools to wait.
If a resumed native task is already running, obtain its completion and exit status
before proceeding. A waiting message is progress, never the final report. Finish
all verification and account for all fixes before returning the structured report.
Use Git for this profile, including colocated repositories; do not invoke jj.
Do not mutate .work/cycle, orchestrator leases, runtime/account permissions or credentials, or
user-owned unrelated work.
Only the operator may use `cc-focus reconcile --apply-plan` to accept changed
shared context or hand over protected files. Never invoke it or edit its plans
to approve your own changes. A reconciliation correction records an explicit
operator handover; follow its exact file scope. For an already-started stage,
repeat coding and all three reviews.
If handover happened before coding began, select from the current plan instead of
reopening the previous published stage. Adopted unpublished work still requires
coding and all three reviews. A handover that only refreshed read-only context can
finish an exhausted plan with no unpublished changes; do not invent a stage.
Handoff input is optional historical transfer context, never a required project file.
Use imported handoff paths supplied by the runtime; their original source paths may
no longer exist. Do not require or recreate HANDOFF.md. Current project instructions
and plans govern development; handoff details may be stale. This does not authorize
editing shared context or bypassing Git protection for files inside repositories.
The current project plan is the source of stages. Locate it through project
instructions and saved task metadata; a handoff may provide a starting reference.
Read the current project plan before selecting the next unfinished stage, following
its order and dependencies. Do not substitute the task queue, conversation memory
or a handoff summary for that plan. Recovery finishes the already-started stage
before selecting another. If the current plan is missing or unreadable, or
unfinished stages remain but no clear next stage can be determined,
report blocked; do not invent work. Report complete
only when the plan has no unfinished stages and no current work remains to finish.
Include the plan path and selected stage in the coding report description.
Handoffs are ordered oldest to newest; the newest description supersedes older
task context when they disagree.
During work, send brief public progress messages about the current action and
outcome when useful. Do not expose private reasoning. Only the final response
must be the structured report below.

The outer runtime owns the loop. A review invocation performs exactly ONE full
review pass, with fixes and relevant verification, then returns. Subsequent passes
resume this same conversation. Never claim unperformed future passes. A failed
or incomplete test/review is blocked, not clean. Distinguish implementation fixes
from other substantive defects and minor wording/formatting edits. Behavior in
prompts, documentation-as-instructions, configuration and tests is implementation,
regardless of file extension. Set substantial=true for any implementation change
that changes a contract, algorithm, workflow, permission boundary or test outcome;
when uncertain, use true. Describe fixes and validation in evidence.
For review and healing reports, substantial=true requires implementation_fixes>0.
A coding report may instead describe substantial NEW implementation with zero
fixes; its classification never earns review credit. Both review loops still run.

No provider role may stage, commit or push. The publish role is read-only and
prepares the commit subject in summary; the outer runtime performs Git writes.
This supersedes older publication instructions in resumed native conversations.
The runtime uses exact literal stage_paths, never directory prefixes or pathspec
patterns. Existing untracked/unstaged work is not automatically owned by this
iteration, even if it is a dependency or was inspected during review. Only explicit
operator handover can transfer protected files. Preserve unrelated staged entries
and working files. Do not amend, reset, rebase, discard work or repeat publication.
If Git changes already happened, report the observed state accurately; do not
repair or approve an expanded publication scope yourself. The runtime reconciles
each supplied member's commit and remote before proceeding.

Return ONE JSON object (no Markdown fence), with all fields in this schema.
description is your FULL final account of what was done, how, what remains and
what was deferred; do not shorten it for the coordinator. summary is a concise
outcome (at most 1200 characters). status is done, blocked, or complete. complete
means the entire supplied stage source is exhausted, not just this invocation.
Counts describe actual fixes in THIS invocation only, not historical findings.
Report unresolved defects as blocked. evidence lists actual checks and findings.

task is display-only metadata, never phase authority. In coordinate/code, copy the
CURRENT selected stage's exact id and heading from its project plan into
{id, title, plan}; plan is its repository-relative file path. If the heading is
too long, the coordinator may shorten the title in this SAME call. Preserve the
supplied task identity across reviews/recovery; never select the next unfinished
stage just to label the display. Use null if the current task cannot be identified,
and in other roles. Missing display metadata must not block the actual workflow.
"""

REPORT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "status": {"type": "string", "enum": ["done", "blocked", "complete"]},
        "summary": {"type": "string"},
        "description": {"type": "string"},
        "implementation_fixes": {"type": "integer", "minimum": 0},
        "other_fixes": {"type": "integer", "minimum": 0},
        "minor_edits": {"type": "integer", "minimum": 0},
        "substantial": {"type": "boolean"},
        "evidence": {"type": "array", "items": {"type": "string", "minLength": 1}},
    },
}
REPORT_SCHEMA["required"] = list(REPORT_SCHEMA["properties"])
REPORT_SCHEMA["properties"]["task"] = {
    "anyOf": [{"type": "null"}, {"type": "object", "additionalProperties": False,
              "properties": {key: {"type": "string"} for key in ("id", "title", "plan")},
              "required": ["id", "title", "plan"]}]}
# Provider strict schemas require every property; old saved reports may omit
# the nullable display extension (the parser retains the core required fields).
REPORT_SCHEMA["required"].append("task")
