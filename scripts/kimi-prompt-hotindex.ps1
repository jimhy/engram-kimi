# engram x kimi - UserPromptSubmit hook adapter (Windows). ASCII-only so Windows PowerShell 5.1 parses it.
# Mirror of kimi-prompt-hotindex.sh.
#
# This is engram's ONLY injection channel on kimi: SessionStart stdout does NOT reach the model
# context (observation-only, verified by experiment), while UserPromptSubmit stdout IS appended.
# So the hot-index is emitted here, gated per session by --state (first prompt of a session /
# scope change -> emit; otherwise silent). The resolved wire.jsonl goes via --transcript to the
# engine's active-session registration (hard-kill catch-up material).
# Best-effort: never break the user's prompt submit; stdout carries ONLY the hot-index text.
if ($env:ENGRAM_REVIEWER -eq '1') { exit 0 }

try {
    # read the hook stdin JSON (session_id / cwd); kimi closes the pipe after writing.
    # kimi writes the JSON as UTF-8 -- force InputEncoding or non-ASCII cwd turns to mojibake.
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    $raw = [Console]::In.ReadToEnd()
    $sid = ''
    try { $sid = [string]($raw | ConvertFrom-Json).session_id } catch {
        if ($raw -match '"session_id"\s*:\s*"([^"]+)"') { $sid = $Matches[1] }
    }

    $scriptDir  = $PSScriptRoot
    # plugin root: kimi injects KIMI_PLUGIN_ROOT into plugin hooks; fall back to the script's parent.
    $pluginRoot = if ($env:KIMI_PLUGIN_ROOT) { $env:KIMI_PLUGIN_ROOT } else { Split-Path -Parent $scriptDir }
    $engram = if ($env:ENGRAM_BIN) { $env:ENGRAM_BIN } else { Join-Path $pluginRoot 'bin\engram-windows-x86_64.exe' }
    if (-not (Test-Path $engram)) { exit 0 }

    $base = Join-Path $env:USERPROFILE '.engram\kimi'

    # resolve this session's wire.jsonl: session_index.jsonl sessionDir mapping first,
    # glob sessions/*/<sid>/agents/main/wire.jsonl as fallback.
    $wire = ''
    if ($sid) {
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
    }

    # --emit text: raw stdout IS the injected context (kimi does not parse the Claude
    # hookSpecificOutput envelope). Re-pipe the raw hook JSON so the engine reads cwd/session_id.
    # Encoding traps measured on Windows PS5.1 (all three must be BOM-less UTF-8):
    #   - $OutputEncoding encodes what we pipe INTO engram's stdin;
    #   - [Console]::OutputEncoding governs how PS5.1 re-encodes piped strings to native stdin --
    #     [Text.Encoding]::UTF8 here prepends an EF BB BF BOM that breaks the engine's JSON parse
    #     (observed: registration fell back to "default"); UTF8Encoding($false) does not;
    #   - it also decodes engram's stdout, so the injected Chinese must go through it as UTF-8.
    $state  = Join-Path $base 'active.state'
    $status = Join-Path $base 'status.txt'
    $log    = Join-Path $base 'hook.log'
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $args_ = @('hot-index', '--from-hook-stdin', '--emit', 'text', '--hook-event', 'UserPromptSubmit',
               '--state', $state, '--status-file', $status, '--log', $log)
    if ($wire) { $args_ += @('--transcript', $wire) }
    $raw | & $engram @args_ 2>$null
}
catch {
    # swallow: injection (if any) already reached stdout; the prompt must proceed.
}
exit 0
