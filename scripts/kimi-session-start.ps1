# engram x kimi - SessionStart hook adapter (Windows). ASCII-only so Windows PowerShell 5.1 parses it.
# Mirror of kimi-session-start.sh.
#
# kimi's SessionStart is observation-only (stdout never reaches the context, verified), so this
# hook does silent bookkeeping only:
#   1. ENGRAM_REVIEWER guard: bail inside the reviewer subprocess (no catch-up, no recursion).
#   2. Catch-up: replay a leftover pending review (previous session ended abnormally), including
#      orphan rebuild from the active-sessions registration when SessionEnd never fired.
# Best-effort: a hook failure must never break session startup -> swallow errors, always exit 0.
if ($env:ENGRAM_REVIEWER -eq '1') { exit 0 }

try {
    # engram speaks UTF-8; decode its stdout as BOM-less UTF-8 (GBK default mangles non-ASCII).
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

    $scriptDir  = $PSScriptRoot
    $pluginRoot = if ($env:KIMI_PLUGIN_ROOT) { $env:KIMI_PLUGIN_ROOT } else { Split-Path -Parent $scriptDir }
    $engram = if ($env:ENGRAM_BIN) { $env:ENGRAM_BIN } else { Join-Path $pluginRoot 'bin\engram-windows-x86_64.exe' }
    if (-not (Test-Path $engram)) { exit 0 }

    $base = Join-Path $env:USERPROFILE '.engram\kimi'
    $work = Join-Path $base 'pending'
    $wm   = Join-Path $base 'watermark.json'
    $sess = Join-Path $base 'active-sessions'

    # catchup-scan is a cheap dir scan; the reviewer it may launch is itself fully detached.
    $planRaw = & $engram catchup-scan --work-dir $work --sessions-dir $sess --watermark $wm 2>$null
    $plan = $null
    if ($planRaw) { try { $plan = ($planRaw | Out-String) | ConvertFrom-Json } catch { $plan = $null } }
    if ($plan -and $plan.action -eq 'review') {
        & (Join-Path $scriptDir 'kimi-launch-reviewer.ps1') `
            -Root $pluginRoot -Engram $engram -Slice $plan.slice `
            -GeneralDb $plan.general_db -ProjectDb $plan.project_db -ProjectName $plan.project_name `
            -Pending $plan.pending -Watermark $wm *>$null
    }
}
catch {
    # swallow: startup must proceed.
}
exit 0
