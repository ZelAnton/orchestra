#!/usr/bin/env bash
# Run proposal_curator in the current folder (Claude Code, auto mode).
# Batch-curates the new P-NNN proposals (kind: proposal) in the backlog: decides one
# outcome for each proposed proposal and creates tasks from the converted ones.
exec claude --agent proposal_curator --permission-mode auto "Per your system prompt, curate the new P-NNN proposals in .work/Tasks_Queue.md and decide one outcome for each proposed proposal. Start now."
