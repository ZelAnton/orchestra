# Codex-native Orchestra package

`generate-codex-agents.ps1` builds this directory from the canonical role instructions
under `agents/`:

- `processor.md` is the root prompt used by `tools/codex-processor-runtime.ps1`;
- `agents/orchestra_*.toml` are namespaced Codex custom agents installed by `cc-sync`
  into `$CODEX_HOME/agents` (normally `~/.codex/agents`).

Do not edit generated files directly. Change the canonical `agents/*.md` instruction or
the provider overlay in `generate-codex-agents.ps1`, then regenerate.
