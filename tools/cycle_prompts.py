"""Fixed sequential profile; deliberately independent of generated queue roles."""

PROFILES = {
    "coordinate": ("codex", "gpt-5.6-luna", "xhigh"),
    "code": ("claude", "opus", "xhigh"),
    "opus": ("claude", "opus", "xhigh"),
    "sol": ("codex", "gpt-6.1-sol", "xhigh"),
    "astra": ("codex", "gpt-6-astra", "xhigh"),
    "opus_final": ("claude", "opus", "xhigh"),
    "final_opus": ("claude", "opus", "max"),
    "final_astra": ("codex", "gpt-6-astra", "max"),
    "claude": ("claude", "claude-fable-5-1", "xhigh"),
    "final_triage": ("codex", "gpt-6-astra", "xhigh"),
    "final_fix": ("claude", "opus", "xhigh"),
    "final_cleanup": ("claude", "opus", "xhigh"),
    "publish": ("codex", "gpt-5.6-luna", "xhigh"),
    "heal": ("codex", "gpt-6-astra", "xhigh"),
}

REVIEW_ROLES = ("opus", "sol", "astra", "opus_final")
FINAL_SCANNERS = ("final_opus", "final_astra", "claude")
READONLY_REVIEW_ROLES = (*FINAL_SCANNERS, "final_triage")
FINAL_ROLES = (*READONLY_REVIEW_ROLES, "final_fix", "final_cleanup")
REVIEW_TARGETS = {role: 2 for role in REVIEW_ROLES}
REVIEW_PROFILE_VERSION = 8

def review_target(state, role):
    """Return the target of the current or most recent review visit."""
    return state.get("review_targets", {}).get(role, REVIEW_TARGETS[role])


PROMPTS = {
    "code": "Implement the next stage. Do not start a review. Do not push.",
    "opus": """Review the current stage after implementation, or do the additional review from the runtime context.
This review needs two consecutive clean passes. Correct defects in this pass.
Opus changes do not cause a return to an earlier role.
Use this separate review session, not the implementation session.

Do one pass. Then return the report.
The runtime selects the next phase. Do not push.

Implementation report:
%%DESCRIPTION%%""",
    "sol": (
        'Review the current stage after Opus. This loop needs two consecutive clean passes. Do'
        ' one pass with defect corrections. Do not push. If this loop has substantial changes,'
        ' first finish the Sol loop. The runtime then runs Opus for two clean passes and '
        'continues directly to Astra.\n\nSmall corrections do not cause this return.\n\n'
        'Implementation report:\n%%DESCRIPTION%%'
    ),
    "astra": (
        'Review the current stage changes. This loop needs two consecutive clean passes. Do '
        'one pass with defect corrections. If this loop has substantial changes, first finish '
        'this loop. The runtime then runs an additional Opus loop for two clean passes. It '
        'continues on the saved route: late Opus or the final round.\n\nSmall corrections do not'
        ' cause this return.'
    ),
    "opus_final": (
        'Do the late Opus/xhigh review after Astra and before the final round.\nReview the '
        'current stage changes. Do one pass with defect corrections.\nThis loop needs two '
        'consecutive clean passes.\nIf this loop has substantial changes, first finish this '
        'loop.\nThe runtime then repeats Astra until it has two clean passes.\n\nSmall changes do'
        ' not need additional Astra review.\nPrefer builds of affected projects and tests of '
        'changed behavior.\nThe runtime permits a full test run here, but it is optional.\n'
        'Explain why the complexity or risk requires a full run.'
    ),
    "final_opus": "Do the first independent inspection of the final round: Opus/max. Use read-only tools.",
    "final_astra": "Do the second independent inspection of the final round: Astra/max. Use read-only tools.",
    "claude": "Do the third independent inspection of the final round: Fable/xhigh. Use read-only tools.",
    "final_triage": (
        'Check ALL findings from the final round, including carried findings. Read the related'
        ' code again. Remove false findings. Make each description clear. Evaluate severity '
        'and the effect on publication. For each source_id, return exactly one decision: '
        'confirmed, rejected, or duplicate.\n\nGive a specific reason for each decision.\n\nA '
        'duplicate must refer to a confirmed finding in this list.\nDo not use a duplicate to '
        'hide a separate defect.\nBefore you reject a corrected defect, check the current code.'
        '\nUse read-only tools.'
    ),
    "final_fix": """Correct the confirmed blockers in final_review.findings for this stage.
Do not select a new stage. Prefer the smallest sufficient corrections.
Build only affected projects and necessary dependencies.
Run only tests that cover the changes. Return a report of the actual corrections.

The next complete final round independently checks the result.
Do not report that review is complete. Nonblocking findings do not require correction to finish this phase.
If the code is already correct, do not make false corrections.
Give evidence that the finding is wrong.
The next complete round and Astra must explicitly check that dispute.""",
    "final_cleanup": (
        (
            'Close ALL remaining confirmed nonblocking findings in final_review.findings after the'
            ' final round.\nThis is a separate Opus/xhigh pass.\nAfter successful closure, the '
            'runtime goes directly to publication without another review.\nCorrect only these '
            'findings in the current stage. Prefer the smallest sufficient corrections. Do not '
            'expand the task.\n\nIf a build is necessary, '
            'build only affected projects and necessary dependencies.\nIf tests are necessary, run '
            'only tests that cover these corrections.\nDo not run a full suite.\nFor each source_id,'
            ' return exactly one resolutions entry with the correction and evidence of closure.\n\n'
            'When you continue an interrupted pass, include completed corrections in your report. '
            'Do not invent changes. Do not mark an open defect as closed. Do not defer an assigned'
            ' finding to the backlog. If a finding remains open, return blocked with the reason '
            'and remaining actions. Do not commit or push.\n\nThe runtime includes these corrections'
            ' in the stage publication.'
        )
    ),
    "publish": """Prepare the reviewed stage for runtime publication.
Inspect the exact supplied stage_paths and current Git state. Use read-only operations.
When the stage is ready, return done.
Use summary as a short imperative commit subject for the affected repositories.
Do not include task identifiers.

The runtime validates your report before it stages, commits, and pushes the changes.
Do not run git add, commit, push, or reset.
Do not change files. Do not claim that publication occurred when you only prepared it.""",
    "coordinate": """Coordinate this sequential main-branch workflow from the short outcome and artifact paths.
Do not implement, review, or start another provider.
Do not change files, commit, or push.
Confirm the proposed phase, or report a specific blocker.

The code phase can recover a lost or rejected report for an implemented stage.
Confirm this report recovery route without doing that work yourself.
Do not require another implementation stage. Do not claim that reviews occurred.
Return complete only when the stage source has no remaining stages or unfinished implementation or publication.
Read public messages and command results only when the short outcome cannot support a decision.""",
    "heal": (
        'You are the separate Astra/xhigh recovery agent, independent of coding and review '
        'roles. Correct the supplied blocker within the existing task and authority. Read the '
        'artifacts from the interrupted invocation. Check the diagnosis. Select safe repairs. '
        'Try those repairs.\n\nCheck the result.\n\nAn earlier request for human help is a claim '
        'to check, not proof that human action is necessary.\nUse existing operator '
        'authorization before you request more.\nComplete routine engineering decisions and '
        'necessary prerequisites within the authorized task, including listed member '
        'repositories.\nDo not merely propose that the operator authorize this work.\nProduct '
        'authentication or authorization code differs from your own execution permissions and '
        'account access.\n\nKeep protected paths and unrelated work unchanged.\nProject '
        'membership does not remove these guards or permit work outside the current task.\n'
        'Return done only after you verify the repair.\nIf repair attempts fail, return '
        'blocked.\nIf a necessary step requires human action, return blocked.\n\nExamples include'
        ' payment, interactive login, a missing secret, or consent or authority that the '
        'operator did not grant.\nState what you checked and tried.\nExplain why the available '
        'authorized alternatives cannot correct the problem.\nGive the exact remaining human '
        'action.\nIf authority is missing, cite the specific rule or refusal.\nDo not infer '
        'missing authority from a filename or another member repository.\n\nDo not commit, push,'
        ' reset, or discard work.\nDo not bypass a refusal or approve an action for the '
        'operator.\nDo not change runtime permissions, account credentials, or execution '
        'permissions.\nDo not delete locks or start another provider.\nImplementation '
        'corrections must pass all required reviews.\nDo not expand the task to unrelated '
        'projects.'
    ),
}

WRITING_CONTRACT = (
    'Instruction and knowledge writing rules:\nUse ASD-STE100 Issue 9 as the style '
    'reference for new or changed instructions and knowledge text.\nUse English unless the '
    "user explicitly requires another language.\nKeep the user's conversation language.\nFor"
    ' another required language, apply the same clarity rules without claiming English '
    'compliance.\n\nUse short sentences, direct verbs, and consistent technical terms.\nGive '
    'one action in each instruction sentence.\nPut a required condition before its action.\n'
    'Use at most 20 words in instructions and 25 words in descriptions.\nKeep each '
    'paragraph on one subject, with at most six sentences.\n\nPreserve every requirement, '
    'prohibition, exception, order, and numeric limit. Preserve exact commands, paths, '
    'identifiers, JSON fields, and quoted evidence. Never remove necessary meaning to meet'
    ' a style target. Meet at least 80 percent of the applicable STE rules. Count an '
    'unchecked applicable rule as unsatisfied. Record justified exclusions and necessary '
    'deviations.\n\nA sentence-length check alone is not an STE compliance assessment.\n\n'
)

COMMAND_EXECUTION_CONTRACT = (
    'Command execution rules for every cc-focus role:\nThese rules limit commands that the '
    'role can already use.\nThey do not permit tools, builds, or tests that the role or '
    'current operation forbids.\nIf the runtime requests REPORT-ONLY CORRECTION, keep its '
    'stricter restrictions.\n\nRun permitted builds, tests, mutation batteries, and '
    'diagnostics synchronously, one command at a time.\nDo not use nohup, shell '
    'backgrounding (&), run_in_background, or another method to detach a command.\nDo not '
    'use Monitor, cron, workflow, or wakeup tools to wait.\nClaude Bash has a default '
    'timeout of 30 minutes.\nFor a long command, it permits up to 21600000 ms (six hours).\n'
    'Keep the command within the remaining six-hour invocation deadline.\n\nRequest a '
    'sufficient timeout explicitly.\nThe timeout is a maximum, not a delay after command '
    'completion.\nDo not sleep for an estimated task duration before you check completion.\n'
    "If a resumed invocation has a running command, collect that SAME command's result and"
    ' exit status.\nUse its existing completion or wait mechanism. Do not start the command'
    ' again.\n\nIf no completion mechanism exists, inspect the known process and result '
    'immediately.\nWhile the command runs, check at intervals of at most 30 seconds.\nStop '
    'waiting as soon as the command finishes.\nA missing process or a quiet log does not '
    'prove success.\nCheck the recorded result. Report missing evidence accurately.\n\nReuse '
    'completed verification for an unchanged candidate when it covers the required check.\n'
    'A waiting message is progress, never the final report.\nFinish all required '
    'verification before you return the structured report.\nInclude all corrections in that'
    ' report.\n\n'
)

CONTRACT = (
    (
        (
            'This is the operator-selected cc-focus profile, not the queue processor.\nIgnore '
            "Orchestra's default model, effort, parallelism, worktree, and review-loop settings.\n"
            'Keep the project coding and safety rules.\nWork only in the existing main checkout or '
            'the listed member main checkouts.\n\nAn iteration can change several member '
            'repositories.\nReview their combined changes.\nThen prepare publication only for the '
            'listed targets, independently for each repository.\nFiles outside the listed '
            'repositories are read-only context.\nDo not create a Git repository at the project '
            'root.\n\nDo not create branches, worktrees, subagents, parallel tasks, or background '
            'jobs.\nDo not call Claude or Codex recursively.\nUse Git, including in colocated '
            'repositories. Do not run jj.\nDo not change .work/cycle, orchestrator leases, '
            'runtime/account permissions, credentials, or unrelated user work.\n\nOnly the operator '
            'can use `cc-focus reconcile --apply-plan` to accept changed shared context or '
            'transfer protected files.\nDo not run this command or edit its plans to approve your '
            'own changes.\nA reconciliation correction records an explicit operator handover.\n'
            'Follow its exact file scope.\nFor a stage that already started, repeat coding and all '
            'required reviews.\n\nIf handover occurred before coding, select from the current plan.\n'
            'Do not reopen the previous published stage.\nTransferred unpublished work still '
            'requires coding and all reviews.\nA handover that only updates read-only context can '
            'finish an exhausted plan if no unpublished changes remain.\nDo not invent a stage.\n\n'
            'Handoff input is optional historical context, not a required project file. Use the '
            'imported handoff paths from the runtime. The original source paths can be absent. Do '
            'not require or recreate HANDOFF.md. The current project instructions and plans govern'
            ' development. Handoff details can be obsolete.\n\nThese rules do not permit shared '
            'context changes or bypass Git protection inside repositories.\n\nUse the current '
            'project plan as the source of stages.\nFind it through project instructions and saved '
            'task metadata.\nA handoff can give an initial reference.\nBefore you select the next '
            'unfinished stage, read the current plan.\nFollow its order and dependencies.\nDo not '
            'replace the plan with the task queue, conversation memory, or a handoff summary.\n\n'
            'During recovery, finish the existing stage before you select another.\nIf the plan is '
            'missing or unreadable, report blocked.\nIf unfinished stages remain without a clear '
            'next stage, report blocked.\nDo not invent work.\nReturn complete only when no '
            'unfinished stages or current work remain.\nInclude the plan path and selected stage in'
            ' the coding report description.\n\nThe runtime orders handoffs from oldest to newest.\n'
            'If task descriptions disagree, the newest description replaces the older context.\n'
            'During work, give short public progress messages when useful.\nDescribe the current '
            'action and result. Do not expose private reasoning.\nOnly the final response must use '
            'the structured report below.\n\nThe outer runtime owns the loop.\nA review invocation '
            'does exactly ONE full pass with corrections and relevant verification.\nThen it '
            'returns a report. Later passes resume this conversation.\nDo not claim future passes '
            'that did not occur.\nA failed or incomplete test or review is blocked, not clean.\n\nAn '
            'explicit REPORT-ONLY CORRECTION request is an exception to ordinary review execution.'
            "\nCorrect only the original pass's JSON report, using its existing evidence.\nUse "
            'read-only operations. Do not repeat checks or change files.\nThis is the same '
            'completed pass, not an additional clean pass.\n\nDistinguish implementation fixes, '
            'other substantive defects, and minor text or format changes.\nBehavior in prompts, '
            'instructions, configuration, or tests is implementation, regardless of the file '
            'extension.\nSet substantial=true for changes to contracts, core algorithms, workflows,'
            ' permission boundaries, or intended test outcomes.\nIf uncertain, use true.\nA local '
            'correction that restores intended behavior can use substantial=false.\nA newly passing'
            ' check alone does not make a correction substantial.\n\nEvaluate the scope and effect, '
            'not only the line count. Describe corrections and validation in evidence. In review '
            'reports, describe every file change in this invocation. This includes review '
            'journals, verification logs, evidence JSON, source snapshots, and digest indexes. A '
            'record of a completed check, without a defect correction, is a minor edit. Count one '
            'minor_edits entry per changed evidence file.\n\nDescribe those writes in evidence.\n\n'
            'Example: a clean review changes only a journal and an evidence index.\nReport '
            'implementation_fixes=0, other_fixes=0, minor_edits=2, and substantial=false.\nMinor '
            'edits do not reset clean-review counters.\nA filename or evidence directory does not '
            'make a behavioral change minor.\nChanges to executable checks, expectations, '
            'acceptance rules, or instructions count as implementation fixes.\n\nCorrections to '
            'false or incomplete substantive evidence count as other_fixes unless they change '
            'behavior.\nIf they change behavior, count them as implementation fixes.\nDo not invent '
            'defect counts to satisfy the report.\nIf a review changes files, at least one edit '
            'counter must be positive.\nFor review and healing reports, substantial=true requires '
            'implementation_fixes>0.\n\nA coding report can describe substantial NEW implementation '
            'with zero fixes. This classification gives no review credit. All required review '
            'loops still run. Review the CURRENT STAGE DIFF from the runtime baseline, including '
            'new files and all changed member repositories. Read surrounding code or dependencies '
            'when necessary to evaluate that diff. A fixing role can report or correct incidental '
            'defects.\n\nDo not turn this work into an unrelated audit of the entire solution.\n\nThe '
            'order is Opus implementation, Opus review, Sol review, Astra review, late Opus '
            'review, then the final round.\nLuna prepares publication after the final round.\nEach '
            'fixing review loop requires TWO consecutive clean passes.\nA clean pass has '
            'implementation_fixes=0 and other_fixes=0.\nMinor edits do not reset the streak.\nA '
            'small correction resets only its own streak.\n\nRemember substantial corrections '
            'throughout the loop.\nFinish that loop before the runtime applies these returns:\n- '
            'Initial or additional Opus does not cause a return.\n- After Sol, run additional '
            'initial Opus for two clean passes, then Astra.\n- After Astra, run additional initial '
            'Opus for two clean passes, then continue the saved route.\n- After late Opus, run '
            'additional Astra for two clean passes, then the final round.\n\nAdditional Astra uses '
            'the same substantial-change rule.\nAfter its additional initial Opus, continue to the '
            'final round.\nDo not repeat late Opus automatically.\nThese rules replace older '
            'ordering in retained conversations.\nOperator changes or recovery edits can invalidate'
            ' all reviews, independently of their size.\n\nThe final round always runs Opus/max, '
            'Astra/max, and Fable/xhigh in sequence.\nRun all three even if an earlier inspection '
            'finds defects.\nThen Astra/xhigh evaluates all findings.\nThese FOUR invocations are '
            'read-only.\nDo not change files, including journals, build, run tests, execute project'
            ' commands, or correct code.\n\nRecord findings only in the structured response. The '
            'runtime writes the records. Static inspection is sufficient evidence for this role. '
            'After a complete inspection, return done even if findings remain. Use blocked only '
            'when you cannot complete the inspection. Keep all fix and edit counters at zero.\n\nDo '
            'not report missing fresh test execution alone as a blocking finding.\n\nFor each '
            'finding, give a specific action, location, evidence or trigger, and severity.\nA '
            'confirmed blocker prevents publication through a proven correctness, safety, '
            'security, or required-contract failure.\nStyle preferences, optional improvements, and'
            ' possible risks without evidence are nonblocking or rejected.\nCritical or high '
            'severity usually blocks publication.\nJustify each decision from its actual effect, '
            'not only the severity label.\n\nAstra must explicitly evaluate every source finding, '
            'including carried findings.\nDo not omit a finding.\nOne COMPLETE round with no '
            'confirmed blockers finishes the inspection loop.\nIf confirmed nonblocking findings '
            'remain, separate Opus/xhigh cleanup closes ALL of them.\nRecord one resolution with '
            'evidence for each source_id.\n\nSuccessful cleanup goes directly to publication with '
            'its corrections, WITHOUT another review or clean-pass loop.\nIf no findings remain, do'
            ' not start cleanup.\nThe runtime keeps the decision and closure history.\nReport '
            'unresolved cleanup work as blocked.\nIf blockers remain, Opus/xhigh corrects them.\n'
            'Then repeat ALL three inspections and the Astra evaluation.\n\nSelect verification from'
            ' the effect of the changes.\nDo not rebuild every project or repeat every test in each'
            ' pass.\nBuild changed projects and directly affected dependencies or consumers only '
            'when necessary.\nRun tests for changed behavior and credible regression risks.\nReuse '
            'recorded results while their relevant inputs and environment remain unchanged.\nA full'
            ' review pass does not require a full test run.\n\nFull test suites are optional.\nAstra '
            'can run them after at least one clean pass in its current loop.\nThat Astra pass must '
            'not make substantive corrections.\nLate Opus can run them when complexity or risk '
            'requires it.\nThe runtime supplies verification.full_run_allowed.\nInitial Opus, Sol, '
            'final blocker repair, and final cleanup use checks limited to affected areas.\n\nFinal '
            'inspectors and Astra evaluation use NO builds or tests, regardless of clean credit.\n'
            'Explain the selected scope, actual commands and results, reused evidence, and '
            'deferred checks.\nDo not claim that a check ran if it did not.\nA failed or incomplete '
            'required check is blocked.\n\nNo provider role may stage, commit or push.\nThe publish '
            'role is read-only and prepares the commit subject in summary.\nThe outer runtime does '
            'the Git writes.\nThis rule replaces older publication instructions in resumed '
            'conversations.\nThe runtime uses exact literal stage_paths, never directory prefixes '
            'or pathspec patterns.\n\nExisting untracked or unstaged work does not automatically '
            'belong to this iteration.\nThis remains true for dependencies and files inspected '
            'during review.\nOnly explicit operator handover can transfer protected files.\nKeep '
            'unrelated staged entries and working files unchanged.\nDo not amend, reset, rebase, '
            'discard work, or repeat publication.\n\nIf Git changes already occurred, report the '
            'actual state.\nDo not repair or approve a larger publication scope yourself.\nThe '
            "runtime checks each supplied member's commit and remote before it continues.\n\nReturn "
            'ONE JSON object with all fields from the schema.\nDo not use a Markdown fence.\nUse '
            'description for the FULL account of completed work, methods, remaining work, and '
            'deferred work.\nDo not shorten it for the coordinator.\nUse summary for a short outcome'
            ' of at most 1200 characters.\n\nUse done, blocked, or complete for status.\nComplete '
            'means that the entire supplied stage source is exhausted, not only this invocation.\n'
            'Count actual fixes and minor edits in THIS invocation only, not historical findings.\n'
            'For REPORT-ONLY CORRECTION, count changes from the ORIGINAL completed review, not the'
            ' correction call.\nInclude new review records without defect corrections in '
            'minor_edits.\n\nOutside the code role, substantial describes THIS invocation only.\nWith'
            " no implementation fixes, set substantial=false.\nDo not copy a prior batch's "
            'substantial=true into a check-only report.\nThe runtime keeps cumulative impact and '
            'required repeated reviews separately.\n\nFixing roles report unresolved required '
            'defects as blocked.\nRead-only final roles return done with structured findings after '
            'a completed inspection.\nUse evidence to list actual checks and findings.\nTask '
            'metadata controls the display only. It never selects a phase.\n\nIn coordinate/code, '
            "copy the CURRENT selected stage's exact id and heading from its project plan into "
            '{id, title, plan}.\nUse a repository-relative file path for plan.\nIf the heading is '
            'too long, the coordinator can shorten title in this SAME call.\nKeep the supplied task'
            ' identity during review and recovery.\nDo not select another unfinished stage only to '
            'label the display.\n\nIf you cannot identify the current task, use null.\nIn other '
            'roles, use null.\nMissing display metadata must not block the actual workflow.\n'
        )
    )
)

REPORT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "status": {"type": "string", "enum": ["done", "blocked", "complete"]},
        "summary": {"type": "string"},
        "description": {"type": "string"},
        "implementation_fixes": {"type": "integer", "minimum": 0},
        "other_fixes": {"type": "integer", "minimum": 0},
        "minor_edits": {"type": "integer", "minimum": 0,
                        "description": (
                            'Count minor changes without behavioral effects. Include one per evidence file that '
                            'records checks without correcting a defect. These changes do not reset clean-review '
                            'counters.'
                        )},
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


# Profile 8: legacy identities above remain readable for interrupted publication.
from focus_pair_profile import PAIRS, PAIR_SCANNERS, PAIR_DISCUSSERS, PAIR_READONLY, PAIR_WRITERS, PAIR_ROLES
PROFILES.update({
    "pair_opus": ("claude", "opus", "xhigh"),
    "pair_sol": ("codex", "gpt-6.1-sol", "xhigh"),
    "pair_astra": ("codex", "gpt-6-astra", "xhigh"),
    "pair_opus_max": ("claude", "opus", "max"),
    "pair_final_opus": ("claude", "opus", "max"),
    "pair_final_fable": ("claude", "claude-fable-5-1", "xhigh"),
    "pair_arbiter": ("codex", "gpt-6-astra", "max"),
    "pair_complexity": ("codex", "gpt-6-sol", "high"),
    "pair_fix": ("claude", "opus", "xhigh"),
    "pair_cleanup": ("claude", "opus", "xhigh"),
    "pair_fix_high": ("claude", "opus", "high"),
    "pair_cleanup_high": ("claude", "opus", "high"),
    "repair_execute": ("claude", "opus", "xhigh"),
    "repair_self": ("claude", "opus", "xhigh"),
    "repair_opus": ("claude", "opus", "xhigh"),
    "repair_astra": ("codex", "gpt-6-astra", "xhigh"),
    "repair_evidence": ("claude", "opus", "xhigh"),
})
for _role in PAIR_SCANNERS:
    PROFILES[_role + "_discuss"] = PROFILES[_role]
READONLY_REVIEW_ROLES = (*READONLY_REVIEW_ROLES, *PAIR_READONLY)
FINAL_ROLES = (*FINAL_ROLES, *PAIR_ROLES)
PAIR_CONTRACT = (
    (
        'Profile 8 replaces ALL earlier review ordering and instructions for reviews that make'
        ' corrections.\nReview only the stage diff and necessary surrounding source across all '
        'listed repositories.\nPair A runs Opus/xhigh and Sol/xhigh concurrently.\nPair B runs '
        'Astra/xhigh and Opus/max concurrently.\nThe final pair runs Opus/max, then '
        'Fable/xhigh.\nKeep each initial report hidden from its partner until BOTH initial '
        'inspections finish.\n\nRepeat each pair while significant findings remain.\nSignificant '
        'means blocking OR severity critical/high/medium.\nOnly nonblocking findings with low '
        'severity are minor.\nIf severity is uncertain, keep the finding significant until '
        'agreement or arbitration resolves it.\nDo not reduce severity merely to leave the '
        'loop.\n\nAfter agreement or arbitration in Pair A, a separate Codex GPT-6-Sol/high '
        'assessor evaluates EVERY accepted repair or diagnostic.\nIt selects Opus/high or '
        'Opus/xhigh for the batch.\nUse the effort required by the most difficult assignment.\n'
        'Do not change accepted findings, severity, scope, or publication requirements during '
        'this assessment.\nUse high for clear local repairs with sufficient evidence.\nUse xhigh'
        ' for interacting changes, architecture or security risks, or uncertainty.\n\nRepair '
        'complexity is independent of finding severity.\nA serious defect can have a simple '
        'repair, and the reverse is also possible.\nThe Opus executor closes ALL accepted '
        'assignments.\nSignificant findings require a new review by the SAME pair after repair,'
        ' even if no source change was necessary.\nAfter minor-only corrections, advance '
        'without repeating the OUTER pair.\nIn B/final, first complete the inner repair gate.\n\n'
        'Unexpected substantial implementation changes or unresolved disputes require another '
        'inspection.\nThere are no returns across pairs or fixed OUTER clean-streak '
        'requirements.\nIf no accepted assignments remain, skip assessment and execution.\nThen '
        'advance. Do not invent edits to start an executor.\n\nInspectors, discussion '
        'participants, the complexity assessor, and the Astra/max arbiter are STRICTLY '
        'READ-ONLY.\nDo not write project journals, build, run tests, execute commands, or call'
        ' another model.\nUse only focus_inspect.\nReport all findings in JSON. The runtime '
        'records them.\nFor each finding, give specific locations, a trigger, the requirement, '
        'and evidence.\n\nDefer only unrelated improvements with low severity.\nGive an explicit '
        'scope reason for such a deferral.\nCorrect accepted stage findings. Do not defer them '
        'to bypass the repair loop.\nAfter a complete inspection, return done even if findings '
        'remain.\nUse blocked only when you cannot do the assigned work.\n\nDo not request '
        'operator approval only because reviewers disagree. After two exchanges, autonomous '
        'Astra/max arbitration is BINDING. A repeated objection is not new evidence. An '
        'endorsement must name the exact supplied proposal hash. It cannot also propose '
        'changes. Otherwise, evaluate EVERY supplied source_id.\n\nKeep open obligations. '
        'Explain counterarguments.\n\nThe arbiter must decide every finding, including '
        'duplicates and carried findings. It can request a specific diagnostic with '
        'action=verify. Only the Opus executor runs that diagnostic. Reuse results. Do not '
        'repeat a diagnostic with a sufficient existing answer. Resolve engineering ambiguity '
        'with the smallest compatible choice and an explicit assumption.\n\nA recorded, reasoned'
        ' disagreement cannot veto arbitration.\n\nUse substantial impact for changes to '
        'contracts, core algorithms, workflows, permission boundaries, or intended test '
        'outcomes.\nA local restoration of intended behavior can be minor.\nIf uncertain, '
        'classify the impact as substantial.\nEvaluate meaning, not file extensions or line '
        'counts.\n\nDuring review phases, only selected pair_fix/pair_cleanup executors or '
        'repair_execute can change code.\nThe selected pair_fix/pair_cleanup effort is high or '
        'xhigh.\nThe repair_execute effort is xhigh.\nThe code role still implements the stage.\n'
        'Correct only accepted assignments. Prefer the smallest sufficient corrections, builds'
        ' of affected projects, and relevant tests.\n\nFull test suites are optional.\nUse them '
        'only for an explicit late-pair assignment with a stated risk reason.\nDo not change '
        'credentials, permissions, runtime records, protected work, HEAD, or staging.\nOnly the'
        ' runtime commits and pushes.\nExecutors return one resolution per assignment with '
        'actual evidence.\nDisputed diagnoses return to the arbiter and must not silently '
        'disappear.\n\nResults from pair_fix require the same pair again.\nExecutor edit counters'
        ' and substantial describe THIS invocation only.\nFor a report-only correction, they '
        'describe the ORIGINAL invocation.\nAn unchanged check-only invocation has zero '
        'counters and substantial=false, even with retained fixed resolutions.\nDo not copy '
        'cumulative batch impact into this flag.\nThe runtime keeps cumulative impact and '
        'required outer review separately.\n\nPAIR A EXECUTION:\nThe pair_fix/pair_cleanup roles,'
        ' including _high variants, fix AND verify accepted assignments.\nThese roles can build'
        ' affected projects and run targeted tests now.\nPair A has NO two-clean-pass inner '
        'gate or mandatory separate test invocation.\nDo not apply the B/final test schedule to'
        ' Pair A, even if an assignment incorrectly refers to that gate.\nComplete required '
        'diagnostics before you return done.\n\nAlways include EVERY assigned source_id.\nIf work'
        ' remains unfinished, use outcome=deferred with the exact remaining check and reason.\n'
        'Do not omit unfinished work, claim it passed, or invent a dispute.\nDeferred means '
        'pending work, not closure or review credit.\nThe runtime can continue the SAME '
        'executor on outstanding assignments with retained work and checks.\n\nIn Pair A, '
        'pair_cleanup closes minor-only findings and advances to B.\nIn B/final, every accepted'
        ' batch uses repair_execute Opus/xhigh and the inner repair gate, including minor '
        'corrections.\nDo not mark unresolved work as resolved.\nUnfinished Pair A assignments '
        'continue with the executor.\nDisputed diagnoses return to the arbiter with evidence.\n'
        'Neither case permits advancement.\n\nLate-pair repair gate (B and final):\nOpus/xhigh '
        'makes the corrections.\nThen it selects self-review or independent Opus/xhigh + '
        'Astra/xhigh pair review from the ACTUAL patch risk.\nEvaluate this risk separately '
        'from finding severity.\nContracts, persistent data, security/permissions, concurrency,'
        ' cross-component changes, core algorithms, or uncertainty require pair review.\nA '
        'simple local repair can use the same executor session for self-review.\n\nReport the '
        'choice, reasons, and risk flags in repair.\nThe mode can become stricter but cannot '
        'become less strict.\nSelf-review and pair review use separate READ-ONLY invocations '
        'with only focus_inspect tools.\nInspect the cumulative repair diff against the '
        'candidate before correction, plus necessary surrounding source.\nThe first clean pass '
        'checks closure and completeness.\nThe second checks regressions, side effects, and '
        'closure again.\n\nCorrect every confirmed relevant finding, including low-severity '
        'findings, before you count clean passes.\nThe runtime requires TWO consecutive clean '
        'passes on exactly the same candidate.\nChanges to code, tests, or expected outputs '
        'invalidate both passes.\nRuntime review artifacts alone do not invalidate them.\nKeep '
        'test results in the JSON report.\nDo not edit project journals during the test '
        'invocation.\n\nIf completed tests already changed a journal, the runtime requests a '
        'separate read-only Opus/xhigh evidence audit.\nThe auditor inspects EVERY exact '
        'changed hunk.\nOnly historical records of the reported completed checks qualify as '
        'evidence-only changes.\nChanges to behavior, requirements, instructions, acceptance '
        'rules, test expectations, or source do not qualify.\nUncertain changes do not qualify.'
        '\nA .md extension or minor_edits count does not grant an exception.\n\nThe evidence '
        'audit must not run tests, edit files, or waive missing evidence.\nIn a test report, '
        'verified can confirm a fix only if an earlier fix invocation recorded fixed for that '
        'assignment.\nIt cannot replace a missing or disputed repair.\nUse the same bounded '
        'communication and arbitration protocol.\nDisagreement does not require the user.\n\nONLY'
        ' B/FINAL repair_execute with operation=fix must not build or test.\nReturn '
        'repair.tests.status=deferred and outcome=deferred for verify assignments.\nThis '
        'restriction does not apply to Pair A pair_fix/pair_cleanup roles.\nReviewers can '
        'request future checks as verification obligations.\nA wait for scheduled tests is not '
        'itself a static defect.\n\nOnly after both clean passes does the executor run tests in '
        'a SEPARATE invocation.\nDo not edit code or tests in that invocation.\nBuild only '
        'affected projects and required dependencies.\nRun only relevant tests unless a '
        'specific existing full_suite obligation requires broader evidence.\nIf no checks '
        'apply, explain why with specific evidence.\nDo not claim that unrun tests passed or '
        'skip required diagnostics.\n\nTest defects return to the correction step.\nThen require '
        'two new clean passes and targeted tests again.\nIf self-review missed a defect, use '
        'pair mode.\nInfrastructure failures retain static credit for an unchanged candidate '
        'and use normal recovery.\nDo not make corrections during the test invocation.\n\nFor '
        'infrastructure status, tests.failures can contain kind=verification obstacles, never '
        'candidate defects.\nCandidate defects require status=failed and kind=defect.\nKeep '
        'failed-check evidence. Mark incomplete verification assignments deferred.\nOn retry, '
        'reuse successful checks from retained_test_results for this unchanged candidate.\n'
        'Repeat only outstanding checks and necessary prerequisites.\n\nThe runtime stores '
        'frozen review inputs in archives, not extra source trees.\nArchive maintenance does '
        'not permit project test changes or prove that a failed check passed.\nOnly after the '
        'inner gate can significant or substantial corrections return to the same expensive '
        'outer pair.\nMinor-only corrections then advance.\nIf there are no accepted tasks, skip'
        ' the inner gate.\n\nSummarize results, not private reasoning.\nRuntime artifacts keep '
        'the mode, evidence, counters, and exact snapshot.\nHandoffs contain short records of '
        'explicit decisions, assumptions, and actual checks, not hidden reasoning.\nAgent '
        'opinions are not requirements.\nKeep uncertainty, failed or unrun checks, and all open'
        ' findings in the records.\nCite original evidence when more detail is necessary.\n\n'
        'Initial final-pair inspections receive only neutral inputs.\nDo not retrieve earlier '
        'sessions or review archives.\nReturn exactly the JSON schema for your role.\nKeep all '
        'edit and fix counters at zero for read-only roles.\n'
    )
)
for _role in PAIR_ROLES:
    PROMPTS[_role] = PAIR_CONTRACT

# Keep legacy reports/roles readable, but never teach old ordering to code,
# coordination, recovery or publication in the current profile.
CURRENT_CONTRACT = (CONTRACT.split("The outer runtime owns the loop.", 1)[0]
    + PAIR_CONTRACT
    + CONTRACT[CONTRACT.index("No provider role may stage, commit or push."):])

CODE_IMPLEMENTATION_CONTRACT = """The code role implements the current stage and checks the implementation.
The runtime schedules Pair A, Pair B, the final pair, and publication after coding.
Return the coding result before these review phases start.
Do not start a review loop, discussion, arbitration, or repair assessment in the code invocation.

Complete the stage requirements from the current project plan.
Keep existing partial work and finish only its remaining implementation and checks.
Use the working files, current plan, saved reports, and public command results to determine completed work.
Keep implementation work focused on the current stage.
If a provider failure prevents completion, report the unfinished work and the public error.

If a build is necessary, build only affected projects and required dependencies.
Run the relevant tests and required diagnostics for the implementation.
Full suites require an explicit late-pair assignment with a stated risk reason.
Reuse completed checks only when their evidence applies to the current files.
Report failed, incomplete, and unrun checks accurately.
Do not skip required checks or claim that unrun checks passed.

Count actual corrections and minor edits made in this invocation.
Changes to behavior, instructions, configuration, or intended test outcomes are implementation changes, regardless of file extension.
Corrections to substantive evidence are other_fixes unless they change behavior.
Count one minor_edits entry per changed evidence file that only records completed checks.
Describe those changes in evidence.

Use substantial=true for changes to contracts, core algorithms, workflows, permissions, or intended test outcomes.
If uncertain, use true.
A local correction that restores intended behavior can use substantial=false.
New implementation can be substantial with zero implementation_fixes.
This coding classification gives no review credit.
All required review phases still follow coding.

Keep the final account factual: implemented behavior, changed files, completed checks, their results, and remaining work.
Use short explanations of explicit decisions and assumptions when they help verify the result.
Follow the supplied report schema.

"""
CODE_CONTRACT = (CONTRACT.split("The outer runtime owns the loop.", 1)[0]
    + CODE_IMPLEMENTATION_CONTRACT
    + CONTRACT[CONTRACT.index("No provider role may stage, commit or push."):])

EXECUTOR_ACCOUNTING_CONTRACT = """Executor report counters:
Count only the changes that this invocation made.
In a report-only correction, "this invocation" means the ORIGINAL invocation, not the correction.
Count changes to source behavior, executable checks, test expectations, acceptance rules, configuration, or instructions as implementation_fixes.
Count corrections of false or incomplete substantive evidence that do not change behavior as other_fixes.
Count comments, formatting, and records of completed checks as minor_edits, one for each changed file.
Do not classify a change from its directory or file extension.

Set substantial=true for changes to contracts, core algorithms, workflows, permission boundaries, or intended test outcomes.
If you are not sure, use true and count that change as an implementation fix.
If substantial is true, implementation_fixes must be at least 1.
The runtime rejects a report that breaks this rule.
If this invocation changed files, at least one counter must be positive.
If it changed no files, set all counters to 0 and substantial=false.

"""


DISCUSSION_CONSENSUS_CONTRACT = """Discussion consensus field:
To endorse the supplied proposal, copy the proposal_hash value from the runtime assignment into consensus.
The consensus value is only these 64 hexadecimal characters.
Do not add words, labels, the impact, or punctuation to consensus.

For an endorsement, set impact to the impact of the supplied proposal.
For an endorsement, leave assessments and new_findings empty.
Put your reasons in summary or description.
If the assignment has no proposal_hash, set consensus to null.
To disagree or to propose changes, set consensus to null and assess every supplied source_id.

"""


def role_contract(role):
    contract = (CODE_CONTRACT if role == "code" else PAIR_CONTRACT if role in PAIR_ROLES
                else CURRENT_CONTRACT if role in ("coordinate", "heal", "publish") else CONTRACT)
    if role in PAIR_WRITERS:
        # PAIR_CONTRACT omits the counter rules of CONTRACT, but the parser enforces them.
        contract += EXECUTOR_ACCOUNTING_CONTRACT
    if role in PAIR_DISCUSSERS:
        # Saved discussion prompts embed PAIR_CONTRACT, so the exact consensus format is added here.
        contract += DISCUSSION_CONSENSUS_CONTRACT
    # Observed Claude coding runs with this block ended in reasoning_extraction
    # refusals. Claude writers load the same policy from user settings.
    # Claude inspectors write no instructions or knowledge text.
    writing = "" if PROFILES[role][0] == "claude" else WRITING_CONTRACT
    return writing + COMMAND_EXECUTION_CONTRACT + contract
