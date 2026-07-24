#!/usr/bin/env bash
# Run the intelligent cross-project inbox curator on demand. Processor invokes the same
# role automatically at safe cohort boundaries; this launcher is the manual trigger.
exec claude --agent inbox_curator --permission-mode auto "Per your system prompt, process this repository's cross-project inbox now. MODE=all. queue_write_mode=auto. ROOT=current repository root."
