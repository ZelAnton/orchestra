# End-of-line (EOL) policy

This repository is developed on Windows with both **git** and **jj** (Jujutsu,
colocated). Two file classes have opposite line-ending needs:

- **`*.cmd`** launchers are multi-line batch programs (`:labels`, `goto`,
  delayed expansion). `cmd.exe` mis-parses them with LF endings, so they **must
  be CRLF**.
- **Everything else** — agent `*.md`, `*.sh`, `*.ps1`, `*.rs`, docs — **must be
  LF**. In particular Claude Code's agent loader parses the YAML front matter of
  `agents/*.md`; a stray `\r` breaks orchestrator agents (e.g. `processor`,
  which then reports `--agent 'processor' not found`).

## Why not just use a tool's EOL conversion

`jj`'s `working-copy.eol-conversion` (`input` / `input-output`) is a single
**global** switch. Setting it to `input-output` to give `.cmd` files CRLF also
rewrites every `.md`/`.sh` to CRLF on checkout, which is what corrupted the
agents. Its per-file behaviour is also unreliable — it does **not** honour
`.gitattributes` the way git does, and its output conversion does not fire
consistently. So we do **not** rely on any checkout-time conversion.

## The policy: the blob is the single source of truth

Every tool checks the working copy out **verbatim**, and the committed blob
already holds exactly the bytes we want on disk:

| Layer | Setting | Effect |
|-------|---------|--------|
| `.gitattributes` (committed) | `* text=auto eol=lf` + `*.cmd -text` | git: LF everywhere; `.cmd` stored/checked out verbatim (CRLF) |
| jj, per repo | `working-copy.eol-conversion = none` | jj materialises blobs byte-for-byte (no conversion) |
| git, per clone | `core.autocrlf = false` | belt-and-suspenders; the explicit attributes already override autocrlf |

`.cmd` is marked `-text` (not `text eol=crlf`) on purpose: `text eol=crlf` keeps
an **LF** blob and relies on checkout conversion, which jj (`eol-conversion=none`)
does not perform — so the working copy would get LF and break. With `-text` the
blob itself is CRLF and no tool ever rewrites it.

## Per-clone setup (NOT carried by the clone)

`.gitattributes` travels with the repo, but the jj repo config
(`.jj/repo/config.toml`) and git local config do **not**. After a fresh clone,
re-apply them:

```sh
jj config set --repo working-copy.eol-conversion none
git config --local core.autocrlf false
```

(If your **global** jj config still sets `working-copy.eol-conversion` to
`input`/`input-output`, prefer reverting it — with this blob-is-truth policy the
global conversion is unnecessary and actively harmful. `jj config unset --user
working-copy.eol-conversion` restores the default, `none`.)

## Recovery — if agents break again ("`--agent '<name>' not found`")

The working copy picked up CRLF. Normalise the should-be-LF files back to LF
(the blobs are already LF, so this only fixes the working copy), then re-sync the
`~/.claude` mirror:

```sh
# from the repo root — convert every tracked non-.cmd text file to LF
git ls-files | while read -r f; do
  case "$f" in *.cmd|*.png|*.jpg|*.ico|*.gif|*.pdf|*.zip|*.exe|*.dll) continue;; esac
  if LC_ALL=C grep -qU $'\r' "$f" 2>/dev/null; then perl -i -pe 's/\r\n/\n/g' "$f"; fi
done
pwsh -NoProfile -File tools/sync-runtime.ps1   # or: cc-sync
```

Then confirm the jj/git configs above are in place so it does not recur.
