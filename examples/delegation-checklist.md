# Delegation checklist

Print this next to any bridge call. Every line corresponds to a failure that actually happened.

## Before

- [ ] `-Doctor` run in this session, and the CLI/version is what you expect
- [ ] The task is **self-contained**: no step needs an answer from the user mid-run
- [ ] Inputs are already extracted and written to disk (PDF → text, repo cloned, data present)
- [ ] Output paths are **absolute** and their directories exist
- [ ] The prompt is in a file (`-PromptFile`), not in argv
- [ ] The prompt states the sandbox and that writing is allowed
- [ ] The prompt contains a **verification command** whose output must be quoted back
- [ ] The prompt says what *not* to do: no installs, no fabrication, "write 未报告 if absent"
- [ ] `-TimeoutSec` ≥ 2× the expected duration (default expectation: 10 min)
- [ ] The call runs in the background, not in a blocking foreground turn

## During

- [ ] `softRetries` growing but the run alive → normal on a bad link, keep waiting
- [ ] `errors[]` containing `workspace routing discovery failed` → it will fall back to HTTPS; only fail if it also times out
- [ ] Nothing on stdout for 3 minutes → still normal (it is reading)

## After

- [ ] `ok == true` **and** `exitCode == 0` (both, not either)
- [ ] The artifact exists, has non-trivial size, and its structure matches the brief (paragraph/table counts)
- [ ] You **read** the artifact — at least the parts you will be quoted on
- [ ] Numbers were spot-checked against the source; percentage vs percentage-point was checked
- [ ] `commands[]` shows nothing unexpected (installs, network calls, deletes)
- [ ] Empty `message` + empty `commands` + `hint` about network → nothing was done; retry once, then report the network honestly
- [ ] Temp dirs cleaned (`scripts/.run`, prompts, smoke files)
