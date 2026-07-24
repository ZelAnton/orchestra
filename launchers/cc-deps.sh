#!/usr/bin/env bash
# Reconcile the current repository's products/direct dependencies into the user registry.
exec claude --agent dependency_curator --permission-mode auto "Per your system prompt, refresh this repository's dependency graph now. MODE=refresh. ROOT=current repository root. WORK=.work. BASE=current committed trunk tip."
