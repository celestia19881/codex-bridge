# Codex CLI reference (what the bridge relies on)

Verified against `codex-cli 0.164.0-alpha.11.1` on Windows. Flags change between releases; `-Doctor` prints the version actually in use, and `codex exec --help` is authoritative.

## Where the binary lives

| Install | Path |
|---|---|
| Desktop app (MSIX `OpenAI.Codex`) | `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe` (one dir per version) |
| Env override | `$env:CODEX_CLI` — the app sets this for its own child processes |
| PATH | `codex.exe` if installed standalone |

`codex-run.ps1` tries `$env:CODEX_CLI` → `%LOCALAPPDATA%\OpenAI\Codex\bin\**\codex.exe` (newest first) → `Get-Command codex.exe`.

## Subcommands that matter

| Command | Use |
|---|---|
| `codex exec [prompt]` | non-interactive run; `--json` for JSONL events. Alias `e` |
| `codex exec resume <SESSION_ID\|name> [prompt]` | continue a thread; `--last` for the newest |
| `codex queue --thread <THREAD> --message <TEXT>` | enqueue a message into an existing session |
| `codex agents` | list sessions on the shared local app-server daemon |
| `codex mcp list \| get \| add` | codex is an MCP **client** — no server mode, so it cannot call back into your agent |
| `codex app-server` / `remote-control` | experimental IPC surfaces; not needed here |
| `codex doctor`, `codex login` | diagnostics and auth |

## `codex exec` flags used by the bridge

| Flag | Why |
|---|---|
| `--json` | machine-readable event stream on stdout |
| `--skip-git-repo-check` | allow running outside a repo |
| `-C, --cd <dir>` | working directory |
| `-s, --sandbox read-only\|workspace-write\|danger-full-access` | tool sandbox. **Omit this and codex may behave as read-only** — pass it explicitly |
| `--ephemeral` | do not persist the session (cheap, but then `resume` is impossible) |
| `-o, --output-last-message <file>` | write the final message to a file — a useful belt-and-braces alternative to parsing events |
| `--output-schema <file>` | force the final message into a JSON Schema |
| `-m, --model` | model override |
| `-c key=value` | config override, e.g. `-c model_provider=custom` |
| `-i, --image` | attach an image |
| `--dangerously-bypass-approvals-and-sandbox` | full bypass; treat as a last resort |

`exec resume` supports `--json`, `--skip-git-repo-check`, `-m`, `-o`, `--output-schema`, `--ephemeral`, `--last`, `--all`, `--worktree`, `--ignore-user-config`. It accepts **neither `-C` nor `-s`** — verified: passing them fails with `error: unexpected argument '-C' found` (exit 2). A resumed turn therefore inherits the original session's working directory and sandbox; set those when the session is created.

## Event schema (`--json`)

One JSON object per line, in this order:

```json
{"type":"thread.started","thread_id":"01a178a4-cef4-7262-bf94-80e2fc0b71e2"}
{"type":"turn.started"}
{"type":"error","message":"Reconnecting... 2/5 (request timed out)"}
{"type":"item.started","item":{"id":"item_2","type":"command_execution",
  "command":"...","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"..."}}
{"type":"item.completed","item":{"id":"item_4","type":"file_change"}}
{"type":"turn.completed","usage":{"input_tokens":42373,"cached_input_tokens":33408,
  "cache_write_input_tokens":0,"output_tokens":76,"reasoning_output_tokens":0}}
```

Parser rules the bridge applies:

- `thread.started.thread_id` → `sessionId` (reusable via `-Session`).
- `item.completed` with `item.type == "agent_message"` → collect `text`; the **last** one becomes `message` (`messageCount` counts them).
- `item.completed` with `item.type == "command_execution"` → `commands[]` with `command` and `exitCode`.
- `item.type == "file_change"` → recorded implicitly; the artifact list is better obtained by globbing the workdir.
- `type == "error"` with `Reconnecting...` or `request timed out` → **soft**, count in `softRetries`, do not fail the run.
- `ok = (exitCode == 0 and turn.completed seen)` — exit 0 alone is not enough, and `turn.completed` alone is not enough.
- A run that ends without `turn.completed` means codex died mid-turn; surface `stderrTail`.

## Sessions

`%USERPROFILE%\.codex\session_index.jsonl` — one JSON object per line:

```json
{"id":"01a14d2d-3c85-7302-b62d-45fa0e2a0438","thread_name":"hello","updated_at":"2026-10-18T04:03:25..."}
```

`-List` prints these newest-first. A thread is only resumable if it was **not** run with `--ephemeral`.

## Config keys that explain behaviour

`%USERPROFILE%\.codex\config.toml` (read by `-Doctor`):

```toml
model_provider = "custom"          # the desktop app routes through its own provider
[model_providers.custom]
wire_api = "responses"             # fallback to HTTPS when wss:// fails
requires_openai_auth = true        # -> auth.json, refreshed in place
supports_websockets = true
[windows]
sandbox = "elevated"               # "elevated" == danger-full-access for codex's own sandbox
```

Two consequences: (1) `auth.json` is rewritten on refresh, so it must live in the real home; (2) WebSocket failures are expected and recoverable.

## Credentials

`%USERPROFILE%\.codex\auth.json` holds `id_token`, `access_token`, `refresh_token`, `account_id`. codex reuses the desktop app's login — there is no separate API key to configure. Never copy this file into another `CODEX_HOME`.

## Known failure strings

| String | Meaning |
|---|---|
| `failed to initialize in-process app-server client: ... (os error 5)` | cannot write `~/.codex` |
| `failed to clean up stale arg0 temp dirs` / `could not create PATH aliases` | same, earlier in startup |
| `workspace routing discovery failed` | cannot reach `chatgpt.com` for routing; then falls back to HTTPS |
| `Falling back from WebSockets to HTTPS transport` | normal on a proxied network |
| `failed to refresh available models: request timed out` | cosmetic |
| `Reconnecting... n/5` | transient; survived by design |
| `参数类型不匹配` (PS 5.1 `ArgumentException`) | `@($genericList)` in PowerShell — use `.ToArray()` |
