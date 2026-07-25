#!/usr/bin/env bash
# engram x kimi - UserPromptSubmit hook (posix). Mirror of kimi-prompt-hotindex.ps1.
#
# 这是 engram 在 kimi 下的【唯一注入通道】：kimi 的 SessionStart 是纯观察事件（stdout 不进
# 上下文，已实测），只有 UserPromptSubmit 的 stdout 会被追加进 prompt 上下文。所以热索引在
# 这里输出，并用 --state 按会话门控（每会话首条 prompt / 作用域切换时才真正 emit，其余静默）。
#
# 另把解析出的 wire.jsonl 经 --transcript 传给引擎做活跃会话登记（强杀/断电时 SessionEnd
# 不触发，下次 SessionStart 的 catchup-scan 据此现场补建 pending）。
#
# Best-effort：任何失败都不得影响用户输入，恒 exit 0；stdout 只承载热索引文本，别的一律不写。
[ "$ENGRAM_REVIEWER" = "1" ] && exit 0

# Windows（Git Bash / msys / cygwin 被当作 hook shell 时）→ 转调同名 .ps1（ELF  Linux 二进制
# 在 Windows 上不可执行，行为统一走 PowerShell 实现）；macOS / Linux 继续下方 POSIX 逻辑。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
  msys*|cygwin*|MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exec powershell -NoProfile -ExecutionPolicy Bypass -File "$script_dir/kimi-prompt-hotindex.ps1"
    ;;
esac

# 读 hook stdin（session_id / cwd）。加 3s 硬超时防管道不关闭挂起（无 timeout 命令则裸读）。
if command -v timeout >/dev/null 2>&1; then
  raw="$(timeout 3 cat 2>/dev/null || true)"
else
  raw="$(cat 2>/dev/null || true)"
fi
jget() { printf '%s' "$raw" | sed -n "s/.*\"$1\"[ ]*:[ ]*\"\\([^\"]*\\)\".*/\\1/p"; }
sid="$(jget session_id)"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# plugin root：kimi 给插件 hook 注入 KIMI_PLUGIN_ROOT；本地开发回退到脚本上一级。
plugin_root="${KIMI_PLUGIN_ROOT:-$(dirname "$script_dir")}"
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in arm64|aarch64) bin="engram-macos-aarch64" ;; *) bin="engram-macos-x86_64" ;; esac ;;
  *)      bin="engram-linux-x86_64" ;;
esac
engram="${ENGRAM_BIN:-$plugin_root/bin/$bin}"
[ -x "$engram" ] || exit 0

base="$HOME/.engram/kimi"

# 由 session_id 解析本会话的 wire.jsonl：先查 session_index.jsonl 的 sessionDir 映射，
# 查不到再 glob sessions/*/<sid>/agents/main/wire.jsonl 兜底（索引缺失/字段序变化时仍可用）。
resolve_wire() {
  _sid="$1"; _kh="${KIMI_CODE_HOME:-$HOME/.kimi-code}"; _idx="$_kh/session_index.jsonl"; _sdir=""
  if [ -f "$_idx" ]; then
    _sdir="$(sed -n "s/.*\"sessionId\"[ ]*:[ ]*\"$_sid\".*\"sessionDir\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p" "$_idx" | tail -1)"
  fi
  if [ -n "$_sdir" ] && [ -f "$_sdir/agents/main/wire.jsonl" ]; then
    printf '%s' "$_sdir/agents/main/wire.jsonl"; return 0
  fi
  for _f in "$_kh"/sessions/*/"$_sid"/agents/main/wire.jsonl; do
    [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}

wire=""
[ -n "$sid" ] && wire="$(resolve_wire "$sid" 2>/dev/null)"

# --emit text：stdout 原文即注入内容（kimi 不解析 Claude 的 hookSpecificOutput 信封）。
# --state 门控：引擎按会话分文件记录上次作用域根，未变则输出为空（不重注入）。
if [ -n "$wire" ]; then
  printf '%s' "$raw" | "$engram" hot-index --from-hook-stdin --transcript "$wire" --emit text \
    --hook-event UserPromptSubmit \
    --state "$base/active.state" --status-file "$base/status.txt" --log "$base/hook.log" 2>/dev/null
else
  printf '%s' "$raw" | "$engram" hot-index --from-hook-stdin --emit text \
    --hook-event UserPromptSubmit \
    --state "$base/active.state" --status-file "$base/status.txt" --log "$base/hook.log" 2>/dev/null
fi
exit 0
