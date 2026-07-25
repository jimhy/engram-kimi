# engram x kimi - launch one detached headless reviewer via `kimi -p` (Windows; posix uses
# kimi-launch-reviewer.sh). Shared by SessionEnd review and SessionStart catch-up.
# ASCII-only so Windows PowerShell 5.1 parses it.
#
# Two measured differences from the Claude launcher:
#   - `kimi -p` does NOT read the prompt from stdin (`-p -` treats "-" as the literal prompt) --
#     the prompt must be a single command-line argument. So instead of a .cmd with stdin
#     redirection we write a one-shot .ps1 that reads the prompt file and passes it as one arg
#     (the filled template is ~10KB, far below the 32K Windows command-line limit).
#   - `kimi -p` never fires lifecycle hooks in print mode (verified), so it cannot recurse;
#     ENGRAM_REVIEWER=1 is still passed as future-proofing.
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Engram,
    [Parameter(Mandatory = $true)][string]$Slice,
    [Parameter(Mandatory = $true)][string]$GeneralDb,
    [Parameter(Mandatory = $true)][string]$ProjectDb,
    [Parameter(Mandatory = $true)][string]$ProjectName,
    [Parameter(Mandatory = $true)][string]$Pending,
    [Parameter(Mandatory = $true)][string]$Watermark,
    [string]$Cli = 'kimi'
)
$ErrorActionPreference = 'Stop'

if ($env:ENGRAM_REVIEWER_KIMI) { $Cli = $env:ENGRAM_REVIEWER_KIMI }

# forward-slash everything that goes into the reviewer's bash commands
$fs = { param($p) if ($p) { $p -replace '\\', '/' } else { $p } }
$slice     = & $fs $Slice
$engramFwd = & $fs $Engram
$general   = & $fs $GeneralDb
$project   = & $fs $ProjectDb
$pending   = & $fs $Pending
$watermark = & $fs $Watermark
$skill     = & $fs (Join-Path $Root 'skills\engram\SKILL.md')

# scope kind: the engine puts a 'workspace' marker next to a management-directory db
# (<dir>/.engram/workspace) -> the reviewer gets workspace consolidation rules.
$kind = 'project'
try {
    $marker = Join-Path (Split-Path -Parent $ProjectDb) 'workspace'
    if (Test-Path -LiteralPath $marker) { $kind = 'workspace' }
} catch {}

$tpl = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\reviewer-prompt.md')
$prompt = $tpl
$prompt = $prompt.Replace('{{TRANSCRIPT}}', $slice)
$prompt = $prompt.Replace('{{ENGRAM}}', $engramFwd)
$prompt = $prompt.Replace('{{GENERAL_DB}}', $general)
$prompt = $prompt.Replace('{{PROJECT_DB}}', $project)
$prompt = $prompt.Replace('{{PROJECT_NAME}}', $ProjectName)
$prompt = $prompt.Replace('{{KIND}}', $kind)
$prompt = $prompt.Replace('{{PENDING}}', $pending)
$prompt = $prompt.Replace('{{WATERMARK}}', $watermark)
$prompt = $prompt.Replace('{{SKILL}}', $skill)

# kimi wire.jsonl format note (the launcher appends per-CLI transcript notes; the template file
# itself stays byte-identical across the three adapters).
$prompt = $prompt + @'

## About this transcript (kimi wire.jsonl)
Each line is a JSON object {"type": ...}:
- type == "context.append_message": a full message {role: "user"|"assistant", content[].text}.
  These are the conversation; read them in order.
- type == "context.append_loop_event" with event.type == "content.part": one assistant content
  part (part.type "text" => visible text, "think" => reasoning).
- event.type == "tool.call" / "tool.result": a tool call and its result, linked flatly by the
  SAME toolCallId (call has name+args, result has result.output). Use these to rebuild the
  "which memory was recalled -> what the model then DID" causal chain — e.g. an `engram recall`
  / `engram list` Bash call whose output then visibly shaped the next assistant action counts as
  real (3rd-tier) use; a recall that was loaded but never acted on does not.
- The injected memory hot-index arrives as injected context around the user prompts (not a
  dedicated line here). Judge real use by whether a recalled item demonstrably influenced an
  action or answer.
- type == "config.update" / "llm.request" / "usage.record" / "step.begin|end" /
  "permission.*" / "tools.*" / "turn.*" are meta noise; ignore them.
- Long tool outputs may be large; skim for the causal chain, do not read every byte.
'@

# ---- proxy derivation: a headless `kimi -p` reviewer behind a corporate/regional proxy cannot
# reach the API on a direct connection. Priority: 1) ENGRAM_REVIEWER_PROXY explicit;
# 2) existing HTTPS_PROXY/https_proxy -> inherit as-is; 3) ALL_PROXY/all_proxy -> set both;
# 4) (Windows only) system proxy registry ProxyEnable=1 with non-empty ProxyServer;
# 5) otherwise leave unset (direct; may fail, diagnosed in the log).
function Get-NormalizedProxy {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $v = 'http://' + $v }
    return $v
}
function Set-ReviewerProxy {
    if ($env:ENGRAM_REVIEWER_PROXY) {
        $p = Get-NormalizedProxy $env:ENGRAM_REVIEWER_PROXY
        $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p
        return
    }
    if ($env:HTTPS_PROXY -or $env:https_proxy) { return }
    $allp = if ($env:ALL_PROXY) { $env:ALL_PROXY } elseif ($env:all_proxy) { $env:all_proxy } else { '' }
    if ($allp) {
        $p = Get-NormalizedProxy $allp
        $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p
        return
    }
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $ps = [string]$reg.ProxyServer
            if ($ps -match 'https=([^;]+)') { $ps = $matches[1] }
            elseif ($ps -match 'http=([^;]+)') { $ps = $matches[1] }
            if ($ps.Trim()) {
                $p = Get-NormalizedProxy $ps
                $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p
            }
        }
    } catch {}
}
Set-ReviewerProxy

# optional reviewer model override: ENGRAM_REVIEWER_MODEL=<model alias> -> kimi -m <alias>
# (baked into the one-shot argv string further below as $modelPrefix; alias charset is safe)
$modelPrefix = ''
if ($env:ENGRAM_REVIEWER_MODEL) { $modelPrefix = '-m "' + ($env:ENGRAM_REVIEWER_MODEL -replace '"', '') + '" ' }

if ($env:ENGRAM_HOOK_DRYRUN -eq '1') {
    Write-Host "[dry-run] reviewer-cli = $Cli $modelPrefix"
    Write-Host "[dry-run] proxy        = $($env:HTTPS_PROXY)"
    Write-Host "[dry-run] slice        = $slice"
    Write-Host "[dry-run] general      = $general"
    Write-Host "[dry-run] project      = $project ($ProjectName, kind=$kind)"
    Write-Host "[dry-run] pending      = $pending"
    Write-Host "[dry-run] watermark    = $watermark"
    Write-Host "[dry-run] skill        = $skill"
    Write-Host "[dry-run] prompt $($prompt.Length) chars"
    return
}

# Launch the reviewer FULLY DETACHED so the hook returns instantly. Same hard-learned rule as the
# Claude launcher: Start-Process -NoNewWindow (UseShellExecute=false) makes the child INHERIT this
# hook's stdout pipe handle, so kimi -- which captures the hook's stdout -- would block until the
# reviewer EXITS. Instead write a one-shot .ps1 that runs the reviewer and does its OWN logging,
# then Start-Process it with -WindowStyle Hidden (UseShellExecute=true), which does NOT inherit
# handles.
#
# Second hard-learned rule (observed: clap error "unknown option '->'"): PS 5.1's native-command
# argument marshalling does NOT escape embedded quotes, so a ~10KB prompt full of `"` gets
# shredded into many argv fragments. The one-shot therefore never passes the prompt through
# PowerShell's `&` operator -- it builds the argv string itself (MSVCR escaping rules) and starts
# kimi via System.Diagnostics.Process.
# Pre-launch sweep: delete engram-review-* leftovers older than 7 days (best-effort).
try {
    $cutoff = (Get-Date).AddDays(-7)
    Get-ChildItem -LiteralPath $env:TEMP -Filter 'engram-review-*' -File -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

$stamp = "$PID-" + (Get-Random)
$promptFile = Join-Path $env:TEMP ("engram-review-" + $stamp + ".txt")
$outFile    = Join-Path $env:TEMP ("engram-review-out-" + $stamp + ".txt")
$errFile    = Join-Path $env:TEMP ("engram-review-err-" + $stamp + ".txt")
$oneShot    = Join-Path $env:TEMP ("engram-review-" + $stamp + ".ps1")
Set-Content -LiteralPath $promptFile -Value $prompt -Encoding UTF8

# Resolve the CLI to a concrete .exe (CreateProcess will not run .cmd/.bat shims without a shell);
# fall back to the bare name and let CreateProcess append .exe / search PATH.
$cliExe = $Cli
try {
    $cmd = Get-Command $Cli -ErrorAction Stop
    if ($cmd.CommandType -eq 'Application' -and $cmd.Source -like '*.exe') { $cliExe = $cmd.Source }
} catch {}

# one-shot .ps1: read the prompt file, MSVCR-quote it by hand, run kimi via Diagnostics.Process
# with async stderr drain (no pipe-buffer deadlock), write out/err, log the tail, self-delete.
# Single quotes in paths are doubled for the generated script literals.
$q = { param($p) "'" + ($p -replace "'", "''") + "'" }
$logScript = Join-Path $Root 'scripts\reviewer-log.ps1'
$hookLog = Join-Path $env:USERPROFILE '.engram\kimi\hook.log'
$oneShotLines = @(
    'function ConvertTo-QuotedArg([string]$s) {',
    '    $sb = New-Object System.Text.StringBuilder',
    '    [void]$sb.Append(''"'')',
    '    $bs = 0',
    '    foreach ($ch in $s.ToCharArray()) {',
    '        if ($ch -eq ''\'') { $bs++; continue }',
    '        if ($ch -eq ''"'') { [void]$sb.Append(''\'' * ($bs * 2 + 1)); $bs = 0 }',
    '        elseif ($bs -gt 0) { [void]$sb.Append(''\'' * $bs); $bs = 0 }',
    '        [void]$sb.Append($ch)',
    '    }',
    '    if ($bs -gt 0) { [void]$sb.Append(''\'' * ($bs * 2)) }',
    '    [void]$sb.Append(''"'')',
    '    return $sb.ToString()',
    '}',
    ('$prompt = Get-Content -Raw -Encoding UTF8 -LiteralPath ' + (& $q $promptFile)),
    ('$psi = New-Object System.Diagnostics.ProcessStartInfo'),
    ('$psi.FileName = ' + (& $q $cliExe)),
    ('$psi.Arguments = ' + (& $q $modelPrefix) + ' + "-p " + (ConvertTo-QuotedArg $prompt)'),
    '$psi.UseShellExecute = $false',
    '$psi.RedirectStandardOutput = $true',
    '$psi.RedirectStandardError = $true',
    '$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8',
    '$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8',
    '$p = [System.Diagnostics.Process]::Start($psi)',
    '# drain both pipes via ReadToEndAsync tasks (no event handlers, no pipe-buffer deadlock;',
    '# the add_ErrorDataReceived pattern was observed to crash the whole wrapper with exit=2',
    '# and leave the reviewer blocked on a full stdout pipe)',
    '$outTask = $p.StandardOutput.ReadToEndAsync()',
    '$errTask = $p.StandardError.ReadToEndAsync()',
    '$p.WaitForExit()',
    '$out = [string]$outTask.Result',
    '$err = [string]$errTask.Result',
    '$ec = $p.ExitCode',
    ('[System.IO.File]::WriteAllText(' + (& $q $outFile) + ', $out, [System.Text.Encoding]::UTF8)'),
    ('[System.IO.File]::WriteAllText(' + (& $q $errFile) + ', $err, [System.Text.Encoding]::UTF8)'),
    ('& powershell -NoProfile -ExecutionPolicy Bypass -File ' + (& $q $logScript) + ' -OutFile ' + (& $q $outFile) + ' -ErrFile ' + (& $q $errFile) + ' -ExitCode $ec -LogFile ' + (& $q $hookLog)),
    'Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue'
)
# UTF8 (BOM in PS5.1) so a non-ASCII TEMP path survives when powershell reads the script.
Set-Content -LiteralPath $oneShot -Value $oneShotLines -Encoding UTF8

# ENGRAM_REVIEWER=1 is inherited by the launched process (ShellExecute passes the parent env),
# so the reviewer's own hooks bail out if kimi ever runs hooks in print mode.
$env:ENGRAM_REVIEWER = '1'
try {
    Start-Process -FilePath 'powershell' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $oneShot + '"') `
        -WindowStyle Hidden -ErrorAction Stop
} catch {
    Write-Host ("engram: failed to launch reviewer: " + $_.Exception.Message)
}
