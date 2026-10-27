<#
.SYNOPSIS
  Drive the locally installed Codex CLI (the agent behind the ChatGPT/Codex desktop app).

.DESCRIPTION
  Non-interactive wrapper around codex.exe that:
    * closes stdin properly (codex otherwise blocks on "Reading additional input from stdin...")
    * sends the prompt through stdin, so prompts with quotes / newlines / CJK never break
    * parses the `codex exec --json` event stream into a stable result object
    * enforces a hard timeout and kills the whole process tree
    * returns a readable summary, or one JSON object with -Json

  Modes
    (default)         new turn            codex exec
    -Session <id|nm>  continue a thread   codex exec resume <id>
    -Last             continue newest     codex exec resume --last
    -Queue <id|name>  enqueue a message    codex queue --thread <id> --message
    -List             list local threads  (reads session_index.jsonl)

.EXAMPLE
  .\tools\codex-run.ps1 -Prompt "Summarize paper.txt in 5 bullets" -Sandbox read-only

.EXAMPLE
  .\tools\codex-run.ps1 -Prompt "Add unit tests" -Sandbox workspace-write -TimeoutSec 900 -Json

.EXAMPLE
  .\tools\codex-run.ps1 -Last -Prompt "Now shorten that to 3 bullets"

.NOTES
  Codex must write to %USERPROFILE%\.codex (auth refresh, in-process app-server temp dirs).
  Under the DSH workspace-write sandbox that write is denied and codex dies with
  "failed to initialize in-process app-server client: Access is denied. (os error 5)".
  So this script must be invoked with elevated sandbox permission (danger-full-access).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Prompt,

    [string]$PromptFile,

    [string]$Workdir = (Get-Location).ProviderPath,

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'workspace-write',

    [string]$Model,

    [string]$Session,

    [switch]$Last,

    [string]$Queue,

    [switch]$List,

    [string]$OutFile,

    [int]$TimeoutSec = 300,

    [switch]$Json,

    [switch]$KeepRaw,

    [switch]$DryRun,

    [string]$Replay,

    [switch]$Doctor,

    [switch]$Persist,

    [string]$CodexCli
)

$ErrorActionPreference = 'Stop'
$script:StartedAt = Get-Date

trap {
    [Console]::Error.WriteLine("[codex-run] INTERNAL ERROR line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)")
    [Console]::Error.WriteLine([string]$_.InvocationInfo.PositionMessage)
    [Console]::Error.WriteLine('[codex-run] TYPE: ' + $_.Exception.GetType().FullName)
    [Console]::Error.WriteLine('[codex-run] STACK: ' + $_.Exception.StackTrace)
    [Console]::Error.WriteLine('[codex-run] INNER: ' + [string]$_.Exception.InnerException)
    [Console]::Error.WriteLine('[codex-run] PSSTACK: ' + $_.ScriptStackTrace)
    exit 9
}

# Emit UTF-8 so captured output (CJK thread names, replies) survives intact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Fail {
    param([string]$Message, [int]$Code)
    [Console]::Error.WriteLine("[codex-run] ERROR: $Message")
    exit $Code
}

# ---------------------------------------------------------------- resolve CLI
if (-not $CodexCli) { $CodexCli = $env:CODEX_CLI }

if (-not $CodexCli -or -not (Test-Path -LiteralPath $CodexCli)) {
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter 'codex.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { $CodexCli = $hit.FullName; break }
    }
}
if (-not $CodexCli -or -not (Test-Path -LiteralPath $CodexCli)) {
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $CodexCli = $cmd.Source }
}
# ---------------------------------------------------------------- doctor
# Preflight report. Works even when the CLI is missing, so it can explain why.
if ($Doctor) {
    $cxHome = Join-Path $env:USERPROFILE '.codex'
    $authPath = Join-Path $cxHome 'auth.json'
    $cfgPath = Join-Path $cxHome 'config.toml'
    $idxPath = Join-Path $cxHome 'session_index.jsonl'
    $info = [ordered]@{}

    if ($CodexCli -and (Test-Path -LiteralPath $CodexCli)) { $info.cli = $CodexCli } else { $info.cli = '(not found)' }
    if ($info.cli -ne '(not found)') {
        try {
            $v = & $info.cli '--version' 2>&1 | Select-Object -First 1
            $info.version = ([string]$v).Trim()
        } catch {
            $info.version = 'error: ' + $_.Exception.Message
        }
    } else {
        $info.version = '-'
    }
    $info.codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { '(default)' }
    $info.auth = if (Test-Path -LiteralPath $authPath) { 'present, ' + (Get-Item -LiteralPath $authPath).Length + ' bytes' } else { 'MISSING -> run: codex login' }
    $info.config = if (Test-Path -LiteralPath $cfgPath) { 'present' } else { 'missing (defaults apply)' }
    if (Test-Path -LiteralPath $cfgPath) {
        $flat = (Get-Content -LiteralPath $cfgPath -Raw) -replace '(?m)^\s*#.*$', ''
        foreach ($key in @('model_provider', 'model', 'wire_api', 'sandbox')) {
            $m = [regex]::Match($flat, '(?m)^\s*' + $key + '\s*=\s*(.+?)\s*$')
            if ($m.Success) { $info['cfg.' + $key] = $m.Groups[1].Value }
        }
    }
    $info.sessions = if (Test-Path -LiteralPath $idxPath) { @(Get-Content -LiteralPath $idxPath | Where-Object { $_.Trim() }).Count } else { 0 }
    $px = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $info.proxyEnabled = if ($px) { [string]$px.ProxyEnable } else { '' }
    $info.proxyServer = if ($px) { [string]$px.ProxyServer } else { '' }

    if ($Json) { $info | ConvertTo-Json -Compress; exit 0 }
    foreach ($k in $info.Keys) { "{0,-15} {1}" -f $k, $info[$k] }
    if ($info.cli -eq '(not found)') { exit 4 }
    exit 0
}

if (-not $CodexCli -or -not (Test-Path -LiteralPath $CodexCli)) {
    Fail 'codex.exe not found. Pass -CodexCli <path> or set $env:CODEX_CLI.' 4
}

# ---------------------------------------------------------------- list mode
if ($List) {
    $index = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
    if (-not (Test-Path -LiteralPath $index)) { Fail "no session index at $index" 4 }
    $rows = @()
    foreach ($line in Get-Content -LiteralPath $index -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $rows += [pscustomobject]@{
            session = $o.id
            name    = $o.thread_name
            updated = $o.updated_at
        }
    }
    $rows = $rows | Sort-Object updated -Descending
    if ($Json) { $rows | ConvertTo-Json -Depth 4 -Compress; exit 0 }
    "{0,-38}  {1,-20}  {2}" -f 'SESSION', 'UPDATED', 'NAME'
    foreach ($r in $rows) {
        "{0,-38}  {1,-20}  {2}" -f $r.session, ([string]$r.updated).Substring(0, [Math]::Min(19, ([string]$r.updated).Length)), $r.name
    }
    exit 0
}

# ---------------------------------------------------------------- resolve prompt
# NB: reading stdin implicitly hangs when the parent keeps the handle open, so
# stdin is only consumed on an explicit `-Prompt -`.
$wantStdin = ($Prompt -eq '-')
if ($wantStdin) { $Prompt = $null }

if (-not $Prompt -and $PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { Fail "prompt file not found: $PromptFile" 5 }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}

if (-not $Prompt -and $wantStdin) {
    $Prompt = [Console]::In.ReadToEnd()
}

if (-not $Prompt -and -not $Queue -and -not $Replay) {
    Fail 'no prompt. Use -Prompt, -PromptFile, -Prompt -, or -Replay <events.jsonl>.' 5
}

if ($Queue -and -not $Prompt) {
    Fail '-Queue needs -Prompt (the message to enqueue).' 5
}

# ---------------------------------------------------------------- build args
$runDir = Join-Path $PSScriptRoot '.run'
if (-not (Test-Path -LiteralPath $runDir)) {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
}
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stdoutPath = Join-Path $runDir "out-$stamp.jsonl"
$stderrPath = Join-Path $runDir "err-$stamp.log"
$stdinPath = Join-Path $runDir "in-$stamp.txt"

[System.IO.File]::WriteAllText($stdinPath, [string]$Prompt, (New-Object System.Text.UTF8Encoding($false)))

function Quote-Arg {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\' * (2 * $bs + 1))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * (2 * $bs)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$argList = New-Object System.Collections.Generic.List[string]
$mode = 'exec'

if ($Queue) {
    $mode = 'queue'
    $argList.Add('queue')
    $argList.Add('--thread'); $argList.Add((Quote-Arg $Queue))
    $argList.Add('--message'); $argList.Add((Quote-Arg $Prompt))
    $argList.Add('-C'); $argList.Add((Quote-Arg $Workdir))
    if ($Model) { $argList.Add('-m'); $argList.Add((Quote-Arg $Model)) }
} else {
    $argList.Add('exec')
    if ($Session) {
        $mode = 'resume'
        $argList.Add('resume'); $argList.Add((Quote-Arg $Session))
    } elseif ($Last) {
        $mode = 'resume'
        $argList.Add('resume'); $argList.Add('--last')
    }

    $argList.Add('--json')
    $argList.Add('--skip-git-repo-check')
    # `exec resume` accepts neither -C nor -s: it inherits the session's cwd and sandbox.
    if ($mode -eq 'exec') {
        $argList.Add('-C'); $argList.Add((Quote-Arg $Workdir))
        if ($Sandbox) { $argList.Add('-s'); $argList.Add((Quote-Arg $Sandbox)) }
    }
    if ($Model) { $argList.Add('-m'); $argList.Add((Quote-Arg $Model)) }
    if ($OutFile) { $argList.Add('-o'); $argList.Add((Quote-Arg $OutFile)) }
    if ($mode -eq 'exec' -and -not $Persist) { $argList.Add('--ephemeral') }
    $argList.Add('-')
}

$argString = ($argList.ToArray() -join ' ')

if ($DryRun) {
    "CLI : $CodexCli"
    "ARGS: $argString"
    "WD  : $Workdir"
    "SBX : $Sandbox"
    exit 0
}

# ---------------------------------------------------------------- run
$stdoutText = ''
$stderrText = ''
$elapsed = 0
$exitCode = 0
$timedOut = $false

if ($Replay) {
    if (-not (Test-Path -LiteralPath $Replay)) { Fail "replay file not found: $Replay" 5 }
    $stdoutText = Get-Content -LiteralPath $Replay -Raw -Encoding UTF8
} else {
    # Two Windows traps this shim works around:
    #  1) this sandbox forbids spawning a child with piped stdio, so streams go to files;
    #  2) Start-Process -PassThru does not report ExitCode, so cmd writes it to a file.
    $ecPath = Join-Path $runDir "ec-$stamp.txt"
    $shimPath = Join-Path $runDir "run-$stamp.cmd"
    $shim = @(
        '@echo off',
        'chcp 65001 >nul 2>nul',
        ('"' + $CodexCli + '" ' + $argString + ' < "' + $stdinPath + '" > "' + $stdoutPath + '" 2> "' + $stderrPath + '"'),
        ('echo %ERRORLEVEL% > "' + $ecPath + '"')
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($shimPath, $shim + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    $proc = $null
    try {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('"' + $shimPath + '"') -PassThru -NoNewWindow
    } catch {
        Fail "could not start codex: $($_.Exception.Message)" 3
    }

    $timeoutMs = [int]([Math]::Max(1, $TimeoutSec) * 1000)
    $finished = $proc.WaitForExit($timeoutMs)
    if ($env:CODEX_RUN_DEBUG) {
        [Console]::Error.WriteLine("[dbg] timeoutMs=$timeoutMs finished=$finished hasExited=$($proc.HasExited) shim=$shimPath")
    }

    if (-not $finished) {
        $timedOut = $true
        try {
            & taskkill.exe /PID $proc.Id /T /F | Out-Null
        } catch {
            try { $proc.Kill() } catch { }
        }
        try { $proc.WaitForExit(10000) | Out-Null } catch { }
    }

    $elapsed = ((Get-Date) - $script:StartedAt).TotalSeconds

    if ($timedOut) {
        $exitCode = 2
    } else {
        $exitCode = 3
        if (Test-Path -LiteralPath $ecPath) {
            $raw = [string](Get-Content -LiteralPath $ecPath -Raw -ErrorAction SilentlyContinue)
            $raw = $raw.Trim()
            if ($raw -match '^-?\d+$') { $exitCode = [int]$raw }
        }
    }

    if (Test-Path -LiteralPath $stdoutPath) { $stdoutText = Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 }
    if (Test-Path -LiteralPath $stderrPath) { $stderrText = Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 }
    Remove-Item -LiteralPath $shimPath, $ecPath -ErrorAction SilentlyContinue
}
# ---------------------------------------------------------------- queue result
if ($mode -eq 'queue') {
    $ok = (-not $timedOut) -and ($exitCode -eq 0)
    $res = [pscustomobject]@{
        ok        = $ok
        mode      = 'queue'
        exitCode  = $exitCode
        timedOut  = $timedOut
        thread    = $Queue
        elapsedSec = [Math]::Round($elapsed, 1)
        stderrTail = if ($stderrText) { ($stderrText -split "`n" | Select-Object -Last 8) -join "`n" } else { '' }
    }
    if ($Json) { $res | ConvertTo-Json -Depth 4 -Compress }
    else {
        if ($ok) { "[codex-run] queued to thread $Queue ($([Math]::Round($elapsed,1))s)" }
        else { "[codex-run] queue FAILED exit=$exitCode"; if ($res.stderrTail) { $res.stderrTail } }
    }
    if (-not $KeepRaw) { Remove-Item -LiteralPath $stdoutPath, $stderrPath, $stdinPath -ErrorAction SilentlyContinue }
    if (-not $ok) { exit 3 }
    exit 0
}

# ---------------------------------------------------------------- parse events
$agentMessages = New-Object System.Collections.Generic.List[string]
$commands = New-Object System.Collections.Generic.List[object]
$hardErrors = New-Object System.Collections.Generic.List[string]
$softRetries = 0
$threadId = $null
$usage = $null
$badLines = 0

if ($stdoutText) {
    foreach ($line in ($stdoutText -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $ev = $null
        try { $ev = $t | ConvertFrom-Json } catch { $badLines++; continue }

        switch ([string]$ev.type) {
            'thread.started' {
                $threadId = [string]$ev.thread_id
            }
            'error' {
                $m = [string]$ev.message
                if ($m -match 'Reconnecting|request timed out|temporarily unavailable') { $softRetries++ }
                else { $hardErrors.Add($m) }
            }
            'item.completed' {
                $it = $ev.item
                if ($null -eq $it) { break }
                if ($it.type -eq 'agent_message') {
                    if ($it.text) { $agentMessages.Add([string]$it.text) }
                } elseif ($it.type -eq 'command_execution') {
                    $commands.Add([pscustomobject]@{
                        command  = [string]$it.command
                        exitCode = $it.exit_code
                    })
                }
            }
            'turn.completed' {
                $usage = $ev.usage
            }
        }
    }
}

$finalMessage = if ($agentMessages.Count -gt 0) { $agentMessages[$agentMessages.Count - 1] } else { '' }
$ok = (-not $timedOut) -and ($exitCode -eq 0)

$hint = ''
if (-not $ok) {
    $blob = "$stderrText`n$finalMessage"
    if ($blob -match 'in-process app-server client|os error 5|Access is denied|PATH aliases') {
        $hint = 'Codex was denied access to %USERPROFILE%\.codex. Re-run this command with sandbox_permissions=danger-full-access.'
    } elseif ($blob -match 'workspace routing discovery failed|error sending request|Reconnecting') {
        $hint = 'Network to chatgpt.com looks unstable/blocked. Start the local proxy (Clash) and/or retry with a longer -TimeoutSec.'
    } elseif ($agentMessages.Count -eq 0 -and $exitCode -eq 0) {
        $hint = 'Codex exited cleanly but produced no agent_message event.'
    }
}

$stderrTail = ''
if ($stderrText) {
    $stderrTail = (($stderrText -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 6) -join "`n"
}

$result = [pscustomobject]@{
    ok               = $ok
    mode             = $mode
    sandbox          = $Sandbox
    exitCode         = $exitCode
    timedOut         = $timedOut
    sessionId        = $threadId
    message          = $finalMessage
    messageCount     = $agentMessages.Count
    commands         = $commands.ToArray()
    commandCount     = $commands.Count
    usage            = $usage
    errors           = $hardErrors.ToArray()
    softRetries      = $softRetries
    elapsedSec       = [Math]::Round($elapsed, 1)
    hint             = $hint
    stderrTail       = $stderrTail
    rawEvents        = if ($KeepRaw) { $stdoutPath } else { $null }
}

# ---------------------------------------------------------------- emit
if ($Json) {
    $result | ConvertTo-Json -Depth 6 -Compress
} else {
    $tag = if ($ok) { 'OK' } else { 'FAIL' }
    $tok = ''
    if ($usage) {
        $tok = "  tokens in=$($usage.input_tokens) cached=$($usage.cached_input_tokens) out=$($usage.output_tokens)"
    }
    "[codex-run] $tag  mode=$mode  sandbox=$Sandbox  exit=$exitCode  $($result.elapsedSec)s$tok"
    if ($threadId) { "session: $threadId" }

    if ($commands.Count -gt 0) {
        "commands run: $($commands.Count)"
        foreach ($c in $commands) {
            $cc = [string]$c.command
            if ($cc.Length -gt 110) { $cc = $cc.Substring(0, 107) + '...' }
            "  [$($c.exitCode)] $cc"
        }
    }

    if ($finalMessage) {
        ''
        '--- reply ---'
        $finalMessage
    }

    if ($hardErrors.Count -gt 0) {
        ''
        '--- errors ---'
        foreach ($e in $hardErrors) { "  $e" }
    }
    if ($stderrTail) {
        ''
        '--- stderr (tail) ---'
        $stderrTail
    }
    if ($hint) {
        ''
        "HINT: $hint"
    }
}

if (-not $KeepRaw) {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath, $stdinPath -ErrorAction SilentlyContinue
}

if ($timedOut) { exit 2 }
if (-not $ok) { exit 3 }
exit 0
