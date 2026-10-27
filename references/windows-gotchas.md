# Windows / sandbox traps

Four bugs, each of which wasted a run. Reproduce them once and you will recognise them forever.

## 1. Outer sandbox blocks `~/.codex` → codex dies at startup

**Symptom**

```
WARNING: failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)
WARNING: proceeding, even though we could not create PATH aliases: 拒绝访问。 (os error 5)
   at path "C:\Users\<you>\.codex\tmp\arg0-windows\codex-arg0..."
Error: failed to initialize in-process app-server client: 拒绝访问。 (os error 5)
```

**Cause.** codex starts an in-process app-server and unpacks an arg0 shim inside `~/.codex/tmp`; it also rewrites `auth.json` when the token refreshes. An agent sandbox that only allows the workspace denies all of it. Note the error does **not** mention the workspace — it looks like a broken install.

**Fix.** Run the wrapper with the host's widest sandbox (DSH: `danger-full-access`; other hosts: whatever "ungoverned" is called there).

**Tempting non-fix.** Mirroring the home dir:

```powershell
# DO NOT SHIP THIS
copy auth.json config.toml into <workspace>\.codex
$env:CODEX_HOME = "<workspace>\.codex"
```

It *works* (codex initialises, no `os error 5`) and then fails with `workspace routing discovery failed`. Worse, it is unsafe: codex rewrites `auth.json` on refresh, so the mirror becomes a second credential store that drifts from the real one and can log the user out of their desktop app. Pay for the sandbox instead.

## 2. Piped stdio cannot be spawned from the sandbox

**Symptom.** Starting codex via `System.Diagnostics.ProcessStartInfo` with `RedirectStandardOutput/Input = true` throws `Win32Exception: 拒绝访问` (`Access is denied`) — the child is never created.

**Cause.** The sandbox forbids named-pipe creation for the child's stdio. `.NET`'s process start with redirection needs anonymous pipes.

**Fix.** File redirection through a generated `.cmd`:

```powershell
$shim = @(
    '@echo off',
    'chcp 65001 >nul 2>nul',
    ('"' + $CodexCli + '" ' + $argString + ' < "' + $stdinPath + '" > "' + $stdoutPath + '" 2> "' + $stderrPath + '"'),
    ('echo %ERRORLEVEL% > "' + $ecPath + '"')
) -join "`r`n"
[System.IO.File]::WriteAllText($shimPath, $shim, (New-Object System.Text.UTF8Encoding($false)))
Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('"' + $shimPath + '"') -PassThru -NoNewWindow
```

Do not "clean this up" into pipes. It is the fix.

## 3. `Start-Process -PassThru` has no `ExitCode`

**Symptom.** `$p.HasExited` is `True`, `$p.ExitCode` is **empty**, so the wrapper reports exit 3 while codex actually exited 0. Measured on PS 5.1.26100: the exit code of a redirected, `-NoNewWindow` child is simply not populated.

**Fix.** The `.cmd` shim writes `%ERRORLEVEL%` to a file; read that file after `WaitForExit`. `WaitForExit(ms)` itself works fine and returns a bool.

## 4. PowerShell 5.1 cannot bind `@($genericList)`

**Symptom.** After codex has already written its artifact, the wrapper dies with

```
...codex-run.ps1 : 参数类型不匹配
    + CategoryInfo : NotSpecified: (:) [], ArgumentException
    + FullyQualifiedErrorId : System.ArgumentException
```

Stack reveals `PSEnumerableBinder.MaybeDebase` → `PSToObjectArrayBinder.Bind` → `System.Linq.Expressions.Expression.Condition`.

**Cause.** The array subexpression operator on a `System.Collections.Generic.List[object]` (as produced by a `[pscustomobject]` accumulator) trips the PS 5.1 binder.

**Fix.** `$list.ToArray()` instead of `@($list)`. Add a script-level `trap` that prints line number, exception type, stack and `ScriptStackTrace` — that is what located this in one shot.

## Bonus: implicit stdin read hangs forever

Reading `[Console]::In.ReadToEnd()` when `[Console]::IsInputRedirected` is true **but the parent keeps the handle open** blocks forever — the process looks hung (observed: 120 s with zero output, then killed). Only read stdin on an explicit request (`-Prompt -`), never implicitly.

## Bonus: CJK mojibake in captured output

PS 5.1 decodes child output with the OEM code page by default (936 on this machine), so `thread_name` came back as `�` garbage. Set it explicitly, before anything else runs:

```powershell
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
```
