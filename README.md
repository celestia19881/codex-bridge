# codex-bridge

An [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills) that lets one coding agent **delegate work to the locally installed Codex CLI** — dispatch a task, resume the thread, queue a follow-up, and read back a structured result.

```powershell
# hand a 20-page paper to codex, get a styled .docx back
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/codex-run.ps1 `
  -PromptFile prompt.txt -Workdir "C:\work\out" -Sandbox workspace-write -TimeoutSec 1200 -Json
```

```json
{"ok":true,"mode":"exec","sandbox":"workspace-write","exitCode":0,
 "sessionId":"01a178c0-...","message":"已生成，全文约4748个汉字：...",
 "commandCount":16,"usage":{"input_tokens":262244,"output_tokens":1185},
 "elapsedSec":556.0,"hint":"","softRetries":4}
```

---

## Why this exists

Calling `codex exec "do the thing"` from inside a sandboxed agent host fails in five distinct ways, and **each failure disguises itself as something else**:

| What you see | What it actually is |
|---|---|
| `failed to initialize in-process app-server client: 拒绝访问。 (os error 5)` | The outer sandbox won't let codex write `~/.codex` — not a permission problem with your task |
| codex answers *"the filesystem is read-only, I will not write"* and produces nothing | You forgot `-s workspace-write`; the agent censored itself. Costs a full run |
| `Win32Exception: Access is denied` when spawning | You used piped stdio. The sandbox forbids it; use file redirection |
| Your wrapper reports exit 3 while codex exited 0 | `Start-Process -PassThru` does not populate `ExitCode`; capture `%ERRORLEVEL%` in a `.cmd` shim instead |
| `参数类型不匹配` (`ArgumentException`) *after* codex already wrote the file | PowerShell 5.1 cannot bind `@($genericList)`; use `.ToArray()` |

Each row is a real bug that cost time on the run this skill was extracted from. The wrapper encodes all five fixes so the next agent doesn't rediscover them.

## What you get

- **One entry point** (`scripts/codex-run.ps1`) with `-Doctor`, `-List`, `-DryRun`, `-Replay`, `-Json`, plus `exec` / `resume` / `queue` modes
- **A contract, not a shell string** — stable JSON fields (`ok`, `sessionId`, `message`, `commands[]`, `usage`, `hint`) so an agent can branch on the result
- **Preflight** that finds the CLI, checks login state, reads the config that actually matters, and reports proxy settings
- **Offline replay** — `-Replay events.jsonl` re-parses a saved event stream so you can iterate on the parser without spending tokens
- **Deliverable tooling** used in the original workflow: `md2docx.py` (markdown → Chinese academic .docx) and `render-docx.ps1` (docx → PDF → PNG for visual QA)
- **A prompt template** that produced a 4,700-character literature report with zero fabricated numbers (see `examples/paper-report-prompt.md`)

## Install

As a skill for an agent (Claude Code, DSH, or any host that reads `SKILL.md`):

```powershell
# Windows: copies into %USERPROFILE%\.dsh\skills\codex-bridge
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

# for ~/.claude/skills instead
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Claude
```

Manual: copy this folder to `<skills dir>/codex-bridge/`. The skill is `SKILL.md` + `scripts/`; nothing else is required at runtime.

## Prerequisites

- **Codex CLI** installed and logged in (`codex login`). Verified against `codex-cli 0.164.0-alpha.11.1`. The desktop app ships the CLI at `%LOCALAPPDATA%\OpenAI\Codex\bin\<id>\codex.exe`; `-Doctor` finds it.
- **Windows** for the tested path (PowerShell 5.1 is fine). `scripts/codex-run.sh` is the POSIX equivalent — see its header for what is and isn't verified.
- Your agent host must grant the wrapper elevated sandbox permission (it needs to write `~/.codex`). Pre-authorize the wrapper once.

## Usage

```powershell
# 1. is everything sane?
.\scripts\codex-run.ps1 -Doctor

# 2. cheap round trip
.\scripts\codex-run.ps1 -Prompt "Reply with exactly: PONG" -Sandbox read-only

# 3. real work, in the background, as JSON
.\scripts\codex-run.ps1 -PromptFile prompt.txt -Workdir C:\work -Sandbox workspace-write -Json

# 4. follow up on the same thread (sessions are ephemeral unless you pass -Persist)
.\scripts\codex-run.ps1 -Prompt "My favourite number is 42" -Persist -Json
.\scripts\codex-run.ps1 -Session <sessionId> -Prompt "What is my favourite number?"

# 5. what has this machine been doing?
.\scripts\codex-run.ps1 -List

# 6. debug a failed run without paying for another one
.\scripts\codex-run.ps1 -Replay scripts\.run\out-54d0052d.jsonl
```

Exit codes: `0` ok · `2` timeout · `3` codex/queue failure · `4` CLI not found · `5` bad arguments · `9` internal error (prints the stack).

## Architecture

```
your agent
   │  prompt file, workdir, sandbox, timeout
   ▼
codex-run.ps1 ──► generated .cmd shim ──► codex exec --json
   │                    │  file redirection (no pipes!)
   │                    └─ echo %ERRORLEVEL% > ec.txt
   ◄── events.jsonl ────┘
   │
   ├─ parse: thread.started / item.completed(agent_message) / turn.completed(usage) / error
   └─ emit: {ok, mode, sandbox, sessionId, message, commands[], usage, hint, elapsedSec}
```

`references/cli-reference.md` documents the CLI surface and the event schema; `references/windows-gotchas.md` documents each trap with its exact error string.

## Limitations

- **One-way.** Codex is an MCP *client*; it has no server, so it cannot call your tools or ask you a question mid-run. Put the acceptance criteria in the prompt.
- **Slow first call.** ~90 s of WebSocket reconnect attempts before HTTPS fallback on a proxied network. Subsequent calls are faster; every call still costs real tokens.
- **Not a parallel task runner.** codex already parallelises internally (`max_threads=6`, `worktree=/root/.codex/worktrees`); two concurrent `codex exec` calls mostly queue behind the same network path.
- **No mid-run approval.** `exec` is non-interactive: anything ambiguous becomes a guess.
- **The `.sh` port is best-effort.** The `dist`-specific Windows failures do not apply there, but it has seen less use than the PowerShell path.

## Verified

Windows 11 · PowerShell 5.1 · `codex-cli 0.164.0-alpha.11.1` · logged in through the ChatGPT desktop app · behind a proxy.

| Check | Result |
|---|---|
| `-Doctor`, both scripts | CLI found, auth present, 14 sessions indexed |
| smoke `PONG`, `-Sandbox read-only` | 142.7 s, exit 0, 14,921 in / 6 out tokens |
| write test, `-Sandbox workspace-write` | 144.9 s, exit 0, artifact written |
| `codex-run.sh` real call (Git Bash) | 126 s, correct reply |
| `-Persist` → `-Session` round trip | 123.8 s then 122.8 s — the resumed turn recalled a fact from the earlier one |
| `-List` / `-DryRun` / `-Replay` | both scripts, success and failure paths |
| network down (pre-VPN) | exit 3, `workspace routing discovery timed out`, empty `message`, actionable `hint` |

**Not verified:** `-Queue` and `-Last` (need a live app window / a newest recorded session), and native macOS or Linux beyond Git Bash. Treat those as untested rather than broken.

## Provenance

Extracted from a real delegation: read a 20-page arXiv paper and produce a Chinese literature report as a `.docx`. 556 s, 16 shell commands, 262 k input tokens, 4,748 characters of prose, 9 pages, and — after QA — three genuine errors in the source paper found (an "improved by 103%" claim that cannot be true, a stop-gradient equation that contradicts the described sparsity, and a "within 1%" claim contradicted by its own 6/200 splits). Details, including the two failed runs that produced this skill's rules: [`CASE-STUDY.md`](CASE-STUDY.md).

## License

MIT — see [LICENSE](LICENSE).
