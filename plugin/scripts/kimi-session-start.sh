#!/usr/bin/env bash
# engram x kimi - SessionStart hook (posix). Mirror of kimi-session-start.ps1.
#
# kimi 的 SessionStart 是纯观察事件（stdout 不进上下文，已实测），注入走
# kimi-prompt-hotindex.sh（UserPromptSubmit）。这里只做两件静默杂务：
#   1. ENGRAM_REVIEWER guard：复盘者子进程内直接退出（不补跑、不递归）。
#   2. catch-up 补跑：上个会话异常收尾（强杀/关窗/断电）留下的 pending，或连 pending 都没
#      落下的孤儿会话（靠 active-sessions 登记现场补建），在这里补跑巩固。
# Best-effort：任何失败都不得影响会话启动，恒 exit 0。
[ "$ENGRAM_REVIEWER" = "1" ] && exit 0

# Windows（Git Bash / msys / cygwin 被当作 hook shell 时）→ 转调同名 .ps1；macOS / Linux 继续。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
  msys*|cygwin*|MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exec powershell -NoProfile -ExecutionPolicy Bypass -File "$script_dir/kimi-session-start.ps1"
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${KIMI_PLUGIN_ROOT:-$(dirname "$script_dir")}"
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in arm64|aarch64) bin="engram-macos-aarch64" ;; *) bin="engram-macos-x86_64" ;; esac ;;
  *)      bin="engram-linux-x86_64" ;;
esac
engram="${ENGRAM_BIN:-$plugin_root/bin/$bin}"
[ -x "$engram" ] || exit 0

base="$HOME/.engram/kimi"

# --sessions-dir/--watermark：孤儿会话补登（UserPromptSubmit 落下的登记 + 行数超水位线
# → 现场补建 pending 再领取）；仍只补最近一场。catchup-scan 本身只是廉价目录扫描，
# 它可能启动的复盘者是完全脱管的，不会拖住会话启动。
plan="$("$engram" catchup-scan --work-dir "$base/pending" \
  --sessions-dir "$base/active-sessions" --watermark "$base/watermark.json" 2>/dev/null)"
case "$plan" in
  *'"action":"review"'*)
    bash "$script_dir/kimi-launch-reviewer.sh" "$plan" >/dev/null 2>&1
    ;;
esac
exit 0
