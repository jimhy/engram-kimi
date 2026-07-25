# engram x kimi - SessionEnd hook adapter (Windows). ASCII-only so Windows PowerShell 5.1 parses it.
# Mirror of kimi-session-end.sh.
#   kimi has a real SessionEnd (matcher: exit), so this mirrors the Claude main plugin: at session
#   close, resolve this session's wire.jsonl from session_id, let review-prepare cut the increment
#   since the watermark + drop a pending, and when the plan says review, launch a fully detached
#   headless `kimi -p` reviewer. A small increment still leaves its pending for the next
#   SessionStart catch-up. ENGRAM_REVIEWER guard: no recursion inside the reviewer.
# Best-effort: never break session teardown; always exit 0.
if ($env:ENGRAM_REVIEWER -eq '1') { exit 0 }

try {
    # engram speaks UTF-8; decode its stdout as BOM-less UTF-8 (GBK default mangles non-ASCII).
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)

    $raw = [Console]::In.ReadToEnd()
    $payload = $null
    try { $payload = $raw | ConvertFrom-Json } catch { $payload = $null }
    $sid = ''; $cwd = ''
    if ($payload) {
        $sid = [string]$payload.session_id
        $cwd = [string]$payload.cwd
    } else {
        if ($raw -match '"session_id"\s*:\s*"([^"]+)"') { $sid = $Matches[1] }
        if ($raw -match '"cwd"\s*:\s*"([^"]+)"') { $cwd = $Matches[1] }
    }
    if (-not $sid) { exit 0 }
    if (-not $cwd) { $cwd = (Get-Location).Path }

    $scriptDir  = $PSScriptRoot
    $pluginRoot = if ($env:KIMI_PLUGIN_ROOT) { $env:KIMI_PLUGIN_ROOT } else { Split-Path -Parent $scriptDir }
    $engram = if ($env:ENGRAM_BIN) { $env:ENGRAM_BIN } else { Join-Path $pluginRoot 'bin\engram-windows-x86_64.exe' }
    if (-not (Test-Path $engram)) { exit 0 }

    $base = Join-Path $env:USERPROFILE '.engram\kimi'
    $work = Join-Path $base 'pending'
    $wm   = Join-Path $base 'watermark.json'

    # resolve this session's wire.jsonl (session_index.jsonl first, glob fallback).
    $wire = ''
    $kimiHome = if ($env:KIMI_CODE_HOME) { $env:KIMI_CODE_HOME } else { Join-Path $env:USERPROFILE '.kimi-code' }
    $idx = Join-Path $kimiHome 'session_index.jsonl'
    if (Test-Path $idx) {
        $sdir = Get-Content -LiteralPath $idx -Encoding UTF8 |
            Where-Object { $_ -match [regex]::Escape('"sessionId":"' + $sid + '"') } |
            Select-Object -Last 1 |
            ForEach-Object { if ($_ -match '"sessionDir":"([^"]+)"') { $Matches[1] } }
        if ($sdir) {
            $cand = Join-Path $sdir 'agents\main\wire.jsonl'
            if (Test-Path $cand) { $wire = $cand }
        }
    }
    if (-not $wire) {
        $hit = Get-ChildItem -Path (Join-Path $kimiHome 'sessions') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName ($sid + '\agents\main\wire.jsonl') } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($hit) { $wire = $hit }
    }
    if (-not $wire) { exit 0 }

    # scope db paths (engine anchors from the session cwd up to the nearest .engram).
    $pathsRaw = & $engram resolve --project-dir $cwd --format json 2>$null
    $paths = $null
    if ($pathsRaw) { try { $paths = ($pathsRaw | Out-String) | ConvertFrom-Json } catch { $paths = $null } }
    if (-not $paths) { exit 0 }

    # cut the increment since the watermark + drop a pending marker.
    $planRaw = & $engram review-prepare --transcript $wire --session-id $sid `
        --watermark $wm --work-dir $work --general-db $paths.general_db `
        --project-db $paths.project_db --project-name $paths.project_name 2>$null
    $plan = $null
    if ($planRaw) { try { $plan = ($planRaw | Out-String) | ConvertFrom-Json } catch { $plan = $null } }
    if ($plan -and $plan.action -eq 'review') {
        & (Join-Path $scriptDir 'kimi-launch-reviewer.ps1') `
            -Root $pluginRoot -Engram $engram -Slice $plan.slice `
            -GeneralDb $plan.general_db -ProjectDb $plan.project_db -ProjectName $plan.project_name `
            -Pending $plan.pending -Watermark $wm *>$null
    }
    # else: leave the pending; next SessionStart catch-up consolidates it once it grows / on restart.
}
catch {
    # swallow: teardown must proceed.
}
exit 0
