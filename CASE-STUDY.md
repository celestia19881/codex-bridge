# Case study — the run this skill was extracted from

Two days, two tasks, five wrapper bugs, and one delegation that worked. Every rule in `SKILL.md` is here as a scar.

## Task

Use the locally installed Codex (desktop app + CLI, `codex-cli 0.164.0-alpha.11.1`, already logged in with the user's ChatGPT account) to read a 20-page arXiv paper and produce a Chinese literature report **as a Word document** — background, related work, core idea, research questions/challenges, insights, method, contributions, experiments, conclusions.

## Phase 1 — proving the bridge at all

The naive `codex exec "..."` inside the agent's sandbox failed immediately:

```
WARNING: failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)
Error: failed to initialize in-process app-server client: 拒绝访问。 (os error 5)
```

Diagnosis path, and what it ruled out:

| Hypothesis | Test | Result |
|---|---|---|
| The exe is broken / not logged in | `codex exec` outside the sandbox, elevated | **works** — 19,448 tokens, returns `PONG` |
| Named pipes are blocked | `Test-Path \\.\pipe\...` | a pipe *does* exist (`OpenAI.CodexSandbox...`), so not that |
| The sandbox blocks piped stdio | `ProcessStartInfo` with redirects | **yes** — `Win32Exception: 拒绝访问` |
| codex needs `~/.codex` writable | mirror the home via `CODEX_HOME` | codex starts, then `workspace routing discovery failed`; and mirroring `auth.json` is unsafe (token refresh would fork credentials) |

Conclusion: **the outer sandbox must allow `~/.codex`, i.e. `danger-full-access`**, and the wrapper must never use pipes.

Then the wrapper itself produced three more bugs, each needing a separate experiment:

1. `Start-Process -PassThru` reports `HasExited=True` but an **empty `ExitCode`** → wrapper said exit 3 while codex exited 0. Fixed by a generated `.cmd` shim that writes `%ERRORLEVEL%` to a file.
2. `参数类型不匹配` (`System.ArgumentException`, stack: `PSEnumerableBinder.MaybeDebase` → `PSToObjectArrayBinder.Bind`) **after** codex had already written its output — `@($genericList)` is a PS 5.1 binder bug; `.ToArray()` fixed it. A script-level `trap` printing line/type/stack found it in one run.
3. An implicit `[Console]::In.ReadToEnd()` hung forever when the parent kept the stdin handle open (froze for 120 s, no output). Now stdin is read only on an explicit `-Prompt -`.

## Phase 2 — the delegation

### Run 1: failed, and it looked like codex's fault

```
ok=false exit=0?  elapsed=250.5s  input_tokens=262244  output_tokens=1185
reply: 当前会话文件系统权限为 read-only，我禁止了越权操作，无法写入任何文件……
```

No artifacts. The wrapper's default `-Sandbox read-only` had been used, so codex self-censored for 250 seconds and then politely reported it.

**Rule extracted:** for any task that writes, pass the sandbox explicitly *and* say it in the prompt.

### Run 2: succeeded

```
ok=true  exit=0  elapsed=556.0s  commands=16
input_tokens=262244  cached=223104  output=1185
artifacts: report.md (4,748 汉字), report.docx
md2docx output: paragraphs=76  tables=3  chars=7012
```

Prompt shape (see `examples/paper-report-prompt.md`): permission statement · absolute input paths · the exact renderer command · nine required sections · "no fabricated numbers, write 论文未报告 if absent" · cite figure/table numbers · 4,500–6,500 characters · quote the verification output · list any problems you find in the paper.

## Phase 3 — QA (the part that made it usable)

The wrapper returned `ok=true`; that only means codex exited cleanly. The report still had to be read.

- Structure edited by hand (two headings promoted, table of terms moved to an appendix) — 3 minutes.
- Regenerated the `.docx` after adding a page-number footer, justified body text, repeated table headers and tighter list spacing → 9 pages, `paragraphs=76 tables=3 chars=7015`.
- Visually verified by rendering to PDF via Word COM and then to PNG (`scripts/render-docx.ps1`), checking page 1 (title block + summary table), page 4 (dense method prose), page 6 (the results table).
- Spot-checked the numbers against the PDF.

### What the QA actually bought

codex found real defects in the paper, which a summary-style report would have laundered into "the paper claims X":

| Finding | Why it matters |
|---|---|
| "Latency reduced by 103%" (Fig. 12) | impossible under the usual definition of a percentage decrease |
| `X̃ = M ⊙ X + (1−M) ⊙ stopgrad(X)` | forward pass still equals `X`, contradicting the described sparsification |
| "all 200 splits within 1%" while the same paragraph reports ~6 splits at 1.0–1.5 **percentage points** | a counting/units claim the source itself contradicts |
| 42% requires a 800 Mbit/s downlink (Fig. 4), far below the 6 Gbit/s default in TABLE II | the headline number needs an unfavourable-to-them condition |
| 71.7% appears only in the introduction; no table reproduces it | unverifiable |
| Title says **LLM** inference; all experiments are **ViT** image classification | scope overstated in the title |

The prompt line "若发现论文本身有明显问题，单独列出" is what produced this. It is the single highest-value sentence in the template.

## Phase 4 — the day after

The next day the network had no route to `chatgpt.com` (TCP 443 refused, no local proxy listening). The same call returned:

```
ok=false  exit=1  elapsed=244s  softRetries=9
errors=["workspace routing discovery timed out"]
message=""  commandCount=0
hint="Network to chatgpt.com looks unstable/blocked. Start the local proxy (Clash)..."
```

No artifact, no invention, an actionable hint, exit 3. **That is the failure mode you want**: loud, diagnosable, and cheap to retry — as opposed to a 250-second run that quietly returns a summary.

## Cost summary

| | value |
|---|---|
| One real delegation (20-page paper → 9-page docx) | 556 s, 262 k input tokens, ~1.2 k output |
| Cheap smoke test (`PONG`) | ~120 s, 15 k input tokens |
| Wasted on the read-only mistake | 250 s |
| Wasted on wrapper bugs (4 runs during development) | ~40 min of wall clock, $0 in tokens |
| WebSocket reconnect overhead per cold call | ~90 s before HTTPS fallback |

## If you take one thing away

The bridge is easy; the discipline is not. **Say what success looks like, name the exact output paths, forbid fabrication, and verify the artifact yourself.** Everything else in this repo is plumbing.
