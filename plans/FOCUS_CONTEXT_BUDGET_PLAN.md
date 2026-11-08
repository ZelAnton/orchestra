# cc-focus context budget for Claude roles: plan

Status: implemented, revision 3.1. The operator confirmed the four decisions below on 2026-11-08. Each reviewer gave two consecutive clean passes.

Revisions:

- Revision 2 uses a constant instead of a configuration key, and it keeps the runtime prompt readable after a compaction.
  It gives a new writer session the earlier handoffs, and it builds the usage record on `ClaudeTrace`.
  It separates the view tool from the legacy inspector, uses the page budget of the view, and moves the reader guidance to `role_contract`.
- Revision 3 keeps the system prompt of a role the same for all its invocations, so a resumed session keeps its cache.
  It writes a readable recovery copy of the prompt and of the operator messages, and it defines the stage handoff records.
- Revision 3.1 adds small corrections from two clean reviews.

## Goal

The weekly Claude limit of the account that runs cc-focus ran out in one week. Development and a review campaign ran at the same time, and they will continue to run in parallel.
This plan reduces the Claude tokens of each role without a change of a provider, a model, or an effort.

The plan has two steps. They change different modules, so they can be implemented and reviewed one after the other or together:

- **Step A** limits the growth of the conversation of each Claude role.
- **Step B** lets pair readers find text without reading whole files.

## Problems now

Claude Code logs of the week of 2026-11-01 give the values below for the cc-focus account.
The cost share uses weights for Opus 5.5, in input tokens. A cache read is 0.05, a one-hour cache write is 2, and an output token is 5.

| Group | Cost share | Average context of each model turn |
| --- | --- | --- |
| Pair readers of the review campaign | 32.9% | 272k |
| Pair readers of development | 29.0% | 186k |
| Pair writers of development | 11.5% | 244k |
| Pair writers of the review campaign | 9.4% | 322k |
| Code role (implementation) | 5.0% | 380k |
| The operator's own Claude Code session and its subagents | 12.3% | 450k–559k |

An earlier analysis named the publish role for the code-role row. That was wrong: the publisher runs on Codex.
The code-role prompt contains the text `"role": "publish"` of the previous stage, and the earlier script used it.

Each model turn reads the whole conversation again from the cache. Thus the cost of a session grows with the number of turns times the size of the conversation:

- The Claude roles run with a context window of one million tokens (`claude-opus-…[1m]`). Claude Code compacts only when the window is almost full.
- A Pair A writer (`pair_fix`, `pair_cleanup`, `pair_fix_high`, `pair_cleanup_high`) keeps one session for the whole stage, across all outer rounds.
- `repair_execute` already gets a new session for each repair batch, in `start_repair`. Its sessions still reached 961k–972k tokens inside one batch of 8–9 invocations.
- A pair reader job (scan, discussion exchange, arbitration) starts a new session. A `repair_self` review and a report repair resume a session. Some scan jobs reached 950k tokens in about 70 turns.
- The readers called `focus_inspect` 51,661 times in the week, with 479 million characters of results.
  The tool can read pages, list paths, and show the stage diff. It cannot search.
  To find one place, a reader reads a large file page by page, and every page stays in the conversation.
- Compared with the week of 2026-10-18, the average context of a reader turn grew from 168k to 231k tokens.
  The cache writes of the readers grew from 73M to 139M.

## Decisions of the operator

The operator confirmed these decisions.

1. Every Claude role gets an automatic compaction window of 400,000 tokens. The model and its one-million window stay.
2. A Pair A writer gets a new Claude session for each new outer pair. Inside one pair, the session stays.
3. Pair readers get a `search` operation in `focus_inspect`. Their role contract tells them to search first and to read only the line ranges that they need.
4. The runtime records the token use of each Claude invocation, so the operator can measure the effect of steps A and B.

## Step A. Limit the conversation of each Claude role

### A1. Automatic compaction window

The installed Claude CLI (2.1.319) reads `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. The environment value has priority over the `autoCompactWindow` setting.
The CLI uses the smaller of this value and the model window. It clamps a value outside 100,000 to 1,000,000 to the nearest limit and warns. It ignores a value that it cannot parse.
It compacts the conversation when the context reaches the window minus a buffer for the summary.

- `cycle_prompts.py` gets the constant `CLAUDE_COMPACT_WINDOW = 400000`, next to `PROFILES`. The profile of cc-focus stays fixed in code, as `AGENTS.md` requires, so there is no configuration key.
- `Transport` adds `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to `command_env`. That value goes into the process environment and into the `env` of `--settings`, like the Bash timeouts.
  The `--settings` value reaches pair readers too, also with empty setting sources.
- The transport already accepts the event `system/compact_boundary`, and the progress line says "conversation compacted".

A compaction keeps a summary and the last messages. It removes the first user message, which holds the runtime assignment and the report schema.
In the logs, one compaction went from 971,115 to 9,004 tokens, and most summaries did not keep the report schema. Thus:

- The transport appends a recovery rule to the system prompt of each Claude invocation. The system prompt survives a compaction.
  The rule names a fixed path for each role in the run store. Thus the system prompt of a role stays the same for all its invocations.
  - A role with file access gets: "After a compaction of the conversation, read your runtime prompt again from `<store>/prompts/<role>.txt`. Then read again the exact lines that a finding or a fix needs."
  - A pair reader gets the same rule with the path `__runtime__/prompt.txt` of `focus_inspect`.
  - The rule text is a constant in `cycle_prompts.py`. The transport adds it after `role_contract()`, so `role_contract_sha256` in diagnose does not change.
- Before each launch, the transport writes the recovery copy of the current attempt's prompt to `<store>/prompts/<role>.txt`.
  - The copy indents the JSON after each prompt marker ("Runtime context:", "Runtime assignment:", "Executor assignment:", and "Report schema:"), so that a role can read it by line ranges.
  - `prompt.txt` of the attempt stays unchanged as the evidence.
  - Writers of one role in one run store run one at a time, so one file for each role is enough. A development run and a review campaign have different stores.
- Operator messages reach a running writer through the stream input, so they are not in the prompt. The transport appends the text of each delivered message to the recovery copy, under the heading "Operator messages".
- A Claude pair reader gets its recovery copy at `<store>/prompts/<role>.txt` too. Parallel readers always have different roles.
- `focus_pair_view.py` gets the path of the reader's recovery copy as a second argument. It serves this file read-only at the path `__runtime__/prompt.txt`.
  A Codex reader gets no `__runtime__` file, because the rule is only for Claude.
  - `freeze_view` refuses a project file with the path `__runtime__/prompt.txt` with `pair-input`, as it refuses the generated names of `__review__/`.
  - `list` and `search` do not show `__runtime__/prompt.txt`. Only `read` serves it.
- A pair reader that still returns an invalid report gets the existing pair-report correction, which sends the full job prompt again. That correction allows at most two repairs.

Risks:
- A compaction costs one model turn with the full context. It saves cost only when more turns follow.
- Many code-role and `repair_execute` sessions pass 400k, so they will compact. A compacted session reads its prompt and its exact lines again.
- The cache of a conversation starts with the tools and the system prompt. A changed system prompt would make each resumed session write its whole history to the cache again.
  The fixed path of each role prevents this. A test checks that two invocations of one resumed session send the same system prompt.
- A newer Claude CLI can ignore the variable without a message. A3 shows this: diagnose reports a session above the window plus a margin without a compaction, together with `claude_code_version`.

### A2. A new Pair A writer session for each outer pair

Today `state["sessions"]` keeps the session of each Pair A writer role for the whole stage.

- When `new_pair` starts a new outer pair, it removes the sessions of `pair_fix`, `pair_cleanup`, `pair_fix_high`, and `pair_cleanup_high` from `state["sessions"]`.
  `new_pair` is the only place that starts an outer pair, and it runs only when no writer invocation is pending.
- Inside one pair, nothing changes. The executor continuation and the report-only corrections keep their session.
  A disputed execution that runs again inside the same pair keeps it too.
- `repair_execute` keeps its rule: a new session for each repair batch. The final-gate pair does not go through `new_pair`, and its sessions do not change. A1 limits both.
- The code role keeps its session for the stage. A1 limits it.
- Discovery of saved executor results (`saved_pair_execution`, `saved_repair_test`, `saved_repair_fix`) uses invocation records, not sessions, so it does not change.

The writer context gets the earlier work of the stage, because a new session does not have it:

- `pair_writer_context` adds the field `stage_handoff`. It lists the executor records of earlier pairs in this stage, from `state["pair_handoff"]`.
  - Each entry of `state["pair_handoff"]` is a reference with a path relative to the run store. `stage_handoff` gives the absolute path.
  - The executor records get the new fields `phase` and `round` when the runtime writes them. `stage_handoff` shows these values when a record has them. Older records do not have them.
  - The list keeps the records from before an operator correction, because `reset_pairs` keeps `pair_handoff`.
  - `stage_handoff` reads each record to show its phase and round. A changed record stops the writer with `pair-evidence`, as a frozen view does.
- The writer prompt says: "Read the stage handoff when you need an earlier decision, assumption, or check. The current assignment, operator corrections, and operator messages have priority."
- The writer gets no other context from earlier pairs. The decision rows of its assignment have no earlier resolutions, so `stage_handoff` is the only source of earlier work.

The refusal guards change too:

- `selected_refusals(correction=True)` in `focus_diagnostics.py` treats only `repair_execute` as a role whose session a correction drops. After A2, a correction also drops the Pair A writer sessions at the next pair.
  Without this change, `cc-focus correct` stops without reason after a refusal of a Pair A writer. `docs/sequential-cycle.md` gets the same change.

Risks:
- A new writer session reads the changed files again. That costs some tokens in each round, but much less than turns over a context of almost one million tokens.
- The writer loses its own reasoning of earlier rounds. The stage handoff keeps the decisions, the assumptions, and the checks.

### A3. Token use of each Claude invocation

`ClaudeTrace` in `focus_diagnostics.py` already reads the Claude stream of each attempt. It removes repeated messages by their id, reads the final `message_delta` usage, and records the peak context and the compactions.
`cc-focus diagnose` already shows these values for each attempt. A3 extends `ClaudeTrace`; it adds no second parser.

- In the stream, one API message appears as several `assistant` events with the same id and the same usage. With `--include-partial-messages`, these events hold interim output counts.
  `ClaudeTrace` therefore counts each message id once and takes the final output count from `message_delta`.
- `ClaudeTrace` keeps running totals for each attempt: model turns, input tokens, cache reads, cache writes split into 5-minute and one-hour writes, and output tokens.
  It also keeps the peak context, the number of compactions, and their `pre_tokens` and `post_tokens`.
  These totals are separate from its bounded lists of messages and events.
- The usage of the compaction call itself is not in the stream. The record states this gap and keeps the `pre_tokens` of each compaction.
- Synthetic messages of the CLI, for example API error notes, do not count as model turns.
- `modelUsage` and `total_cost_usd` of the result event cover the whole session, also earlier invocations of a resumed session. A3 does not use them.
- The transport writes one file `usage-<attempt>.json` for each attempt into the invocation directory, also for retries, refusal restarts, and reader report repairs.
  Each file names the iteration, the role, the run store, the session, the attempt, and `claude_code_version` from the init event.
  Pair job directories have no `intent.json`, so these fields are necessary for aggregation.
- `cc-focus status` shows the totals of the current iteration of the current run store. `cc-focus diagnose` shows the values of each attempt, and the warning of A1 when a session passes the window without a compaction.
- These values are measurements for the operator. The runtime does not stop or change a role because of them.

## Step B. Let pair readers search

### B1. A search operation for the frozen view

`focus_pair_view.py` serves `focus_inspect` from the frozen view of a pair, for Claude readers through MCP and for Codex readers as a dynamic tool.
Today it uses the tool schema `READ_TOOL` of `focus_readonly.py`. The legacy `Inspector` of the Codex final roles uses the same schema.

- `focus_readonly.py` gets a separate schema `VIEW_TOOL` for the frozen view. `READ_TOOL` and the legacy `Inspector` do not change, so they never advertise search.
  - `serve()` in `focus_pair_view.py` uses `VIEW_TOOL`.
  - The Codex `thread/start` in `cycle_transport.py` uses `VIEW_TOOL` for the `PAIR_READONLY` roles and `READ_TOOL` for the other read-only roles.
- `VIEW_TOOL` adds `search` to the operations and the property `pattern` as a required string or null. Strict Codex schemas require every property, so null is the value for the other operations.
- `ViewInspector.call` accepts the old four keys without `pattern` and the new five keys. A resumed Codex thread keeps the tools of its thread start, so it can still send the old form.
- Search arguments:
  - `path` is a file or a directory of the view. `.` is the whole view.
  - `pattern` is a literal, case-sensitive text of 1 to 200 characters, without NUL and without a line break. Another value is an argument error.
  - A non-null `pattern` with `read`, `list`, or `diff` is an argument error too.
  - `offset` counts matches from zero. `limit` is 1 to 200 for search. The schema keeps its maximum of 500 for the other operations.
- The result lists each matching line as `path:line (row N): text`. N is the row offset that `read` uses for the part with the match, because `read` splits a long line into parts of 6,000 characters.
  The text is a window of at most 400 characters around the first match in the line.
- The result stops at the page budget of the view: `PAGE` of 30,000 UTF-8 bytes, with the next-offset notice. That keeps it below the MCP result limit of Claude.
- The search uses the same frozen files as `read`. A file search uses the exact name rule of `read`, and a directory search the prefix rule of `list`.
  It skips binary files (with a NUL byte) and link entries, and it never reads outside the view.
- The server opens the snapshot archive once for each call. It keeps the verified text of the files that a search read, up to 64 MiB in each inspector. It removes the oldest files first.
  Codex inspectors run in the cc-focus process, and two readers can run in parallel, so the limit applies to each one.
  The search stops after `offset + limit + 1` matches, so a Codex search in the transport loop stays short.
- The tool description names the new operation: "Search first. Then read only the line ranges that you need."
- The `inspection` text of the pair assignment (`focus_pairs.py`) says "Use focus_inspect list/read/diff". It changes to name search. That text is part of saved pair prompts. `_STYLE_TEXT` applies an entry only when the target hash matches, so both old texts need an entry to the new text:
  - a new entry maps `dd350639…` to the new text;
  - a new entry maps `abe1288a…` to the new text.
  The existing entry `dd350639…` → `abe1288a…` stays for older test fixtures. In production it never matches the current text.

### B2. Reading guidance in the role contract

`role_contract()` in `cycle_prompts.py` adds these sentences for the `PAIR_READONLY` roles, like `DISCUSSION_CONSENSUS_CONTRACT` for discussers:

- "Use search to find a name, a requirement ID, or a heading. Then read only the lines that you need."
- "Do not read a large file from its start to find one place."
- "Read each instruction file once in one conversation. Read it again only after a compaction."

The role contract is the system prompt, not a part of saved job prompts. Thus `PAIR_CONTRACT` does not change, and no `_EARLIER_CONTRACTS` entry is necessary. Writers do not get the reader guidance.

Risks:
- A reader can miss a defect that a full reading would show. The guidance limits only the search for places. A reader still reads every file of its scope that it must judge.
- A Codex reader of a resumed thread gets the new guidance through `developerInstructions`, but it keeps its old tool definition without search.
  It can make a few failed search calls before it reads by pages.

## Measurement

1. A3 comes first. Its values for two days of normal work give a baseline per role.
2. After A1, A2, and B, the same values give the effect.
3. Success means two results, compared with the baseline. No Claude reader or writer attempt has a peak context above 450k tokens.
   The average cache reads of a pair reader job fall by at least 30%. The comparison adds `pre_tokens` of each compaction as an estimated read, and it shows the number of compactions.

All steps were installed together, so the baseline comes from the protocol logs of earlier runs.
The measurement script below reads these logs with the same `ClaudeTrace` that writes the usage records.

### Baseline

The baseline period is 2026-11-06 and 2026-11-07. On both days, development and a review campaign ran in parallel.
The period has 501 Claude attempts in 482 jobs. The logs came from three run stores:

- `/srv/dev/projects/Interlink/.work/cycle` (development)
- `/srv/dev/projects/wt-Interlink/review/.work/cycle/review-runs/d5745d5824164c96a94a420a459ad65d` (review campaign)
- `/srv/dev/projects/wt-Interlink/review/.work/cycle/review-runs/79034d9f9029441ab10395b658f79ef1` (review campaign)

| Value | Baseline | Target |
| --- | --- | --- |
| Attempts with a peak context above 450k | 163 of 501 (33%), maximum 972k | 0 |
| Mean cache reads of a pair reader job, with compaction `pre_tokens` | 4.05M (median 1.44M, 354 jobs) | 2.84M or less |
| Mean cost of a pair reader job (extra value, not a criterion) | 1.08M | — |
| Compactions | 10 | — |

The cost is a weighted token count, with the input token as 1. A cache read is 0.05, a five-minute cache write is 1.25, a one-hour cache write is 2, and an output token is 5.
These weights give an estimate. The limit of the subscription has its own count.

| Group | Share of the cost | Median peak |
| --- | --- | --- |
| Pair readers | 78% | 282k |
| `repair_execute` | 12% | 410k |
| Pair A writers | 7% | 393k |
| `code` | 3% | 639k |

The review campaign had 56% of the cost, and development had 44%.
One-hour cache writes were 54% of the cost, output tokens 25%, and cache reads 21%.
A new session writes almost all of its context to the cache, so a lower peak also decreases the writes.

| Reader role | Jobs | Reads per job | Turns per job | Cost per job | Median peak |
| --- | --- | --- | --- | --- | --- |
| `repair_opus` | 69 | 4.35M | 18.7 | 1.42M | 404k |
| `pair_opus_max` | 22 | 18.23M | 45.1 | 3.06M | 769k |
| `pair_opus` | 35 | 8.64M | 28.8 | 1.90M | 455k |
| `pair_opus_max_discuss` | 44 | 1.96M | 11.1 | 0.89M | 261k |
| `pair_opus_discuss` | 70 | 0.89M | 7.9 | 0.55M | 173k |
| `repair_opus_discuss` | 60 | 0.55M | 6.5 | 0.35M | 105k |
| `pair_final_opus` | 6 | 17.87M | 44.3 | 3.08M | 708k |
| `pair_final_fable` | 6 | 16.08M | 53.7 | 2.35M | 577k |
| `repair_self` | 18 | 1.24M | 5.0 | 0.48M | 322k |
| `pair_final_opus_discuss` | 10 | 1.44M | 11.0 | 0.66M | 212k |
| `pair_final_fable_discuss` | 10 | 0.66M | 8.1 | 0.38M | 122k |
| `repair_self_discuss` | 4 | 0.36M | 1.2 | 0.10M | 340k |

Limits of the baseline:

- The stream does not show the usage of a compaction call. The `pre_tokens` of each compaction stand for its read.
- Old logs have no compaction window. Thus the warning `window_exceeded_without_compaction` has no meaning for them.
- Compare the reader roles one by one too. A different mix of jobs changes the mean of all reader jobs.

### Measurement script

The script reads the protocol logs of the run stores and writes nothing. Run it as a user that can read the stores.
For the effect, measure two days of parallel work after the installation. Use the run stores of that period.
Save the Python code below as `measure.py`.

```sh
python3 -B measure.py /srv/dev/projects/orchestra/tools 2026-11-06 2026-11-07 \
  /srv/dev/projects/Interlink/.work/cycle \
  /srv/dev/projects/wt-Interlink/review/.work/cycle/review-runs/d5745d5824164c96a94a420a459ad65d \
  /srv/dev/projects/wt-Interlink/review/.work/cycle/review-runs/79034d9f9029441ab10395b658f79ef1
```

```python
"""Claude usage of cc-focus run stores for one period. Read-only: it reads protocol logs and writes nothing.

python3 -B measure.py ORCHESTRA_TOOLS FIRST_DAY LAST_DAY STORE...
Days are local dates (YYYY-MM-DD) of the attempt start. A store is a directory with invocations/.
"""
import collections, datetime, statistics, sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from focus_diagnostics import scan_claude_invocation
from focus_pair_profile import PAIR_A_WRITERS, PAIR_READONLY

# Relative weights of the token kinds, with the input token as 1. A write without a duration split counts as a one-hour write.
WEIGHTS = {"input_tokens": 1, "cache_read_input_tokens": 0.05, "cache_write_5m": 1.25, "cache_write_1h": 2, "output_tokens": 5}
first, last = (datetime.date.fromisoformat(day) for day in sys.argv[2:4])


def cost(usage):
    unsplit = max(0, usage["cache_creation_input_tokens"] - usage["cache_write_5m"] - usage["cache_write_1h"])
    return sum(usage[key] * weight for key, weight in WEIGHTS.items()) + unsplit * WEIGHTS["cache_write_1h"]


def reads(usage):
    """Cache reads plus the pre_tokens of each compaction, because the stream does not show a compaction call."""
    return usage["cache_read_input_tokens"] + sum(item.get("pre_tokens", 0) for item in usage["compactions"])


rows = []
for store in sys.argv[4:]:
    for target in sorted((Path(store) / "invocations").iterdir()):
        if target.is_dir() and not target.is_symlink():
            for row in scan_claude_invocation(target):
                if row["started"] and first <= datetime.date.fromtimestamp(row["started"]) <= last:
                    rows.append(dict(row, store=store))
if not rows:
    sys.exit("No Claude attempts in this period.")

total = sum(cost(r["usage"]) for r in rows)
over = sum(r["usage"]["peak_context"] > 450000 for r in rows)
print(f"Period {first}..{last}: {len(rows)} attempts, {len({(r['store'], r['invocation']) for r in rows})} jobs, cost {total / 1e6:.0f}M")
print(f"Criterion 1: {over} of {len(rows)} attempts have a peak above 450k ({100 * over / len(rows):.0f}%), "
      f"maximum {max(r['usage']['peak_context'] for r in rows) / 1e3:.0f}k, compactions {sum(r['usage']['compaction_count'] for r in rows)}")

jobs = collections.defaultdict(collections.Counter)
for r in rows:
    if r["role"] in PAIR_READONLY:
        job = jobs[(r["store"], r["invocation"], r["role"])]
        job["reads"] += reads(r["usage"])
        job["cost"] += cost(r["usage"])
        job["turns"] += r["usage"]["turns"]
        job["peak"] = max(job["peak"], r["usage"]["peak_context"])
if jobs:
    values = [job["reads"] for job in jobs.values()]
    print(f"Criterion 2: {len(values)} pair reader jobs, mean reads {statistics.mean(values) / 1e6:.2f}M, "
          f"median {statistics.median(values) / 1e6:.2f}M")
    print(f"Extra: mean cost of a pair reader job {statistics.mean(job['cost'] for job in jobs.values()) / 1e6:.2f}M")
    print(f"\n{'reader role':26} {'jobs':>4} {'reads/job':>9} {'turns/job':>9} {'cost/job':>8} {'peak median':>11}")
    by_role = collections.defaultdict(list)
    for (_, _, role), job in jobs.items():
        by_role[role].append(job)
    for role, items in sorted(by_role.items(), key=lambda kv: -sum(job["cost"] for job in kv[1])):
        n = len(items)
        print(f"{role:26} {n:4} {sum(j['reads'] for j in items) / n / 1e6:8.2f}M {sum(j['turns'] for j in items) / n:9.1f} "
              f"{sum(j['cost'] for j in items) / n / 1e6:7.2f}M {statistics.median(j['peak'] for j in items) / 1e3:10.0f}k")

groups = collections.defaultdict(list)
for r in rows:
    role = r["role"] or "unknown"
    groups["pair readers" if role in PAIR_READONLY else "Pair A writers" if role in PAIR_A_WRITERS else role].append(r)
print(f"\n{'group':16} {'attempts':>8} {'share':>6} {'peak median':>11}")
for name, items in sorted(groups.items(), key=lambda kv: -sum(cost(r["usage"]) for r in kv[1])):
    share = 100 * sum(cost(r["usage"]) for r in items) / total
    print(f"{name:16} {len(items):8} {share:5.0f}% {statistics.median(r['usage']['peak_context'] for r in items) / 1e3:10.0f}k")
parts = {key: sum(r["usage"][key] * weight for r in rows) for key, weight in WEIGHTS.items()}
print("\nCost parts: " + ", ".join(f"{key} {100 * value / total:.0f}%" for key, value in parts.items()))
```

## Tests

- **A1.**
  - A Claude invocation gets `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000` in the environment and in `--settings`, also a pair reader.
  - The system prompt of a role with file access names `<store>/prompts/<role>.txt`. The system prompt of a pair reader names `__runtime__/prompt.txt`.
  - Two invocations of one resumed session send the same system prompt.
  - The recovery copy has the indented assignment and the delivered operator messages.
  - `focus_inspect` reads `__runtime__/prompt.txt` of the job, and no other file under `__runtime__`. `list` and `search` do not show it.
  - `freeze_view` refuses a project file with the path `__runtime__/prompt.txt`.
  - A stream with `compact_boundary` completes, and the usage record counts the compaction.
  - A compacted reader that returns an invalid report gets the pair-report correction with the full job prompt.
- **A2.**
  - A new outer pair removes the four Pair A writer sessions, and the next executor starts a new session.
  - The continuation, the report-only correction, and a disputed execution that runs again inside one pair keep the session.
  - The code role and `repair_execute` keep their rules, and the final-gate pair keeps its sessions.
  - The writer context lists the executor records of earlier pairs as `stage_handoff`, with absolute paths, and with phase and round when the record has them.
  - `selected_refusals(correction=True)` accepts a correction after a refusal of a Pair A writer.
- **A3.**
  - Repeated `assistant` events of one message id count once. The output count comes from `message_delta`.
  - Several attempts in one invocation directory give one usage file each.
  - A resumed session does not count its earlier invocations again.
  - The cache writes are split by duration, and the compactions keep `pre_tokens`.
  - `cc-focus status` shows the totals of the current iteration, and diagnose shows the window warning.
- **B1.**
  - A search finds literal text in a file and in a directory of the view, in path and line order.
  - Search results page by matches and by the page budget.
  - A match in a long line gives the right row offset.
  - Binary files and links are skipped, and a search cannot read outside the view.
  - Invalid patterns, and a pattern with another operation, are refused.
  - The text cache of an inspector stays below its limit.
  - The old four-key form still works for Claude and for a Codex dynamic tool.
  - The legacy `Inspector` and `READ_TOOL` do not change.
  - Reader jobs saved with the current and with the older `inspection` text still match after the change.
  - `serve()` and the Codex `thread/start` of a `PAIR_READONLY` role use `VIEW_TOOL`.
- **B2.**
  - Only `PAIR_READONLY` roles get the reading guidance.
  - `PAIR_CONTRACT` does not change.
  - The `SOURCES` map of `tools/check_focus_instructions.py` lists `VIEW_TOOL`, the reader guidance, and the recovery rule. The check reports 0 findings.

## Documentation

- `docs/sequential-cycle.md`:
  - the compaction window and the recovery rule;
  - the writer session of each pair, the stage handoff, and the correction rule for refusals;
  - the usage record and the search operation.
- `knowledge.md`: the module notes and the new runtime artifacts: `<store>/prompts/<role>.txt`, `usage-<attempt>.json`, and the reserved view path `__runtime__/`.
- `docs/focus-instruction-style-audit.md`: an addendum for the new provider text.

## Implementation steps

1. A3.
2. A1, with the recovery rule and `__runtime__/prompt.txt`.
3. A2, with the stage handoff and the refusal guard.
4. B1 and B2.

Step A and step B change different modules. Both change the system prompt text of pair readers, but in different places: A1 in the transport, B2 in `role_contract`.

## Out of scope

- A change of a provider, a model, or an effort. The operator decides these separately.
- Moving roles from Claude to Codex.
- A stop of parallel work, for example a pause of the review campaign during development.
- The operator's own Claude Code sessions. The operator can start fresh reviewer agents for each review series.
