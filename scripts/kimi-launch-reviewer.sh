#!/usr/bin/env bash
# engram x kimi - 起一个完全脱管的 headless 复盘者（`kimi -p`，posix 版；
# Windows 走 kimi-launch-reviewer.ps1）。由 kimi-session-end.sh 与 kimi-session-start.sh 共用。
# 参数 1 = 引擎输出的 plan JSON（review-prepare / catchup-scan），字段用 sed 抽取，无 jq 依赖。
#
# 与 Claude/codex 启动器的两点差异（已实测）：
#   - `kimi -p` 不从 stdin 读 prompt（`-p -` 会把 "-" 当字面 prompt）——prompt 必须作为
#     单个命令行参数传入（填充后的模板 ~10KB，远低于 Windows 32K 命令行上限）。
#   - `kimi -p` 非交互模式不触发会话生命周期 hook，天然不递归；ENGRAM_REVIEWER=1 仍照传，
#     作为未来 kimi 在 -p 下也跑 hook 时的保险。
plan="$1"
[ -n "$plan" ] || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${KIMI_PLUGIN_ROOT:-$(dirname "$script_dir")}"
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in arm64|aarch64) bin="engram-macos-aarch64" ;; *) bin="engram-macos-x86_64" ;; esac ;;
  *)      bin="engram-linux-x86_64" ;;
esac
engram="${ENGRAM_BIN:-$plugin_root/bin/$bin}"
prompt_tpl="$plugin_root/scripts/reviewer-prompt.md"
skill="$plugin_root/skills/engram/SKILL.md"
wm="$HOME/.engram/kimi/watermark.json"
hook_log="$HOME/.engram/kimi/hook.log"
kimi="${ENGRAM_REVIEWER_KIMI:-kimi}"

jget() { printf '%s' "$plan" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
slice="$(jget slice)"; general="$(jget general_db)"; project="$(jget project_db)"
pname="$(jget project_name)"; pending="$(jget pending)"

# 交给复盘者 bash 的所有路径统一正斜杠。两步：先 JSON 反转义（plan 里 Windows 路径是
# C:\\Users\\... 双反斜杠形式，sed 原样抽出）还原成单反斜杠，再转正斜杠
# （复盘者的 bash 会吃掉反斜杠；POSIX 上无反斜杠，两步都是恒等操作）。
unesc() { local p="$1"; p="${p//\\\\/\\}"; printf '%s' "${p//\\//}"; }
slice="$(unesc "$slice")"; general="$(unesc "$general")"; project="$(unesc "$project")"
pending="$(unesc "$pending")"; engram="${engram//\\//}"

# 作用域类型：管理目录库旁边有 'workspace' 标记（<dir>/.engram/workspace）
# → 复盘者应用 workspace 巩固规则。
kind="project"
[ -f "$(dirname "$project")/workspace" ] && kind="workspace"

[ -f "$prompt_tpl" ] || exit 0
prompt="$(cat "$prompt_tpl")"
prompt="${prompt//"{{TRANSCRIPT}}"/$slice}"
prompt="${prompt//"{{ENGRAM}}"/$engram}"
prompt="${prompt//"{{GENERAL_DB}}"/$general}"
prompt="${prompt//"{{PROJECT_DB}}"/$project}"
prompt="${prompt//"{{PROJECT_NAME}}"/$pname}"
prompt="${prompt//"{{KIND}}"/$kind}"
prompt="${prompt//"{{PENDING}}"/$pending}"
prompt="${prompt//"{{WATERMARK}}"/$wm}"
prompt="${prompt//"{{SKILL}}"/$skill}"

# kimi wire.jsonl 格式说明（让复盘者正确读转录；格式说明由启动器追加，不进模板文件——
# 与 codex/opencode 同款约定，保证 reviewer-prompt.md 三端逐字节一致）。
prompt="$prompt

## About this transcript (kimi wire.jsonl)
Each line is a JSON object {\"type\": ...}:
- type == \"context.append_message\": a full message {role: \"user\"|\"assistant\", content[].text}.
  These are the conversation; read them in order.
- type == \"context.append_loop_event\" with event.type == \"content.part\": one assistant content
  part (part.type \"text\" => visible text, \"think\" => reasoning).
- event.type == \"tool.call\" / \"tool.result\": a tool call and its result, linked flatly by the
  SAME toolCallId (call has name+args, result has result.output). Use these to rebuild the
  \"which memory was recalled -> what the model then DID\" causal chain — e.g. an \`engram recall\`
  / \`engram list\` Bash call whose output then visibly shaped the next assistant action counts as
  real (3rd-tier) use; a recall that was loaded but never acted on does not.
- The injected memory hot-index arrives as injected context around the user prompts (not a
  dedicated line here). Judge real use by whether a recalled item demonstrably influenced an
  action or answer.
- type == \"config.update\" / \"llm.request\" / \"usage.record\" / \"step.begin|end\" /
  \"permission.*\" / \"tools.*\" / \"turn.*\" are meta noise; ignore them.
- Long tool outputs may be large; skim for the causal chain, do not read every byte."

# ---- 代理派生：headless `kimi -p` 复盘子进程走企业代理/地区代理时才够得着 API。
# 优先级：① ENGRAM_REVIEWER_PROXY 显式指定；② 已有 HTTPS_PROXY/https_proxy → 继承不动；
# ③ ALL_PROXY/all_proxy → 据以设两者；④ 都没有 → 不设（直连，可能失败，留给日志诊断）。
# 值可能是 host:port（无 scheme），统一补 http://。export 后由下方 nohup 子进程继承。
engram_norm_proxy() {
  case "$1" in
    *://*) printf '%s' "$1" ;;
    *)     printf 'http://%s' "$1" ;;
  esac
}
if [ -n "${ENGRAM_REVIEWER_PROXY:-}" ]; then
  _p="$(engram_norm_proxy "$ENGRAM_REVIEWER_PROXY")"
  export HTTPS_PROXY="$_p" HTTP_PROXY="$_p"
elif [ -n "${HTTPS_PROXY:-}" ] || [ -n "${https_proxy:-}" ]; then
  :  # 继承环境里已有的代理
elif [ -n "${ALL_PROXY:-}" ] || [ -n "${all_proxy:-}" ]; then
  _src="${ALL_PROXY:-$all_proxy}"
  _p="$(engram_norm_proxy "$_src")"
  export HTTPS_PROXY="$_p" HTTP_PROXY="$_p"
fi

# 复盘者模型覆盖（可选）：ENGRAM_REVIEWER_MODEL=<模型别名> → kimi -m <别名>。
model_args=""
[ -n "${ENGRAM_REVIEWER_MODEL:-}" ] && model_args="-m ${ENGRAM_REVIEWER_MODEL}"

if [ "$ENGRAM_HOOK_DRYRUN" = "1" ]; then
  echo "[dry-run] reviewer-cli = $kimi $model_args"
  echo "[dry-run] proxy        = ${HTTPS_PROXY:-}"
  echo "[dry-run] slice        = $slice"
  echo "[dry-run] general      = $general"
  echo "[dry-run] project      = $project ($pname, kind=$kind)"
  echo "[dry-run] pending      = $pending"
  echo "[dry-run] watermark    = $wm"
  echo "[dry-run] skill        = $skill"
  echo "[dry-run] prompt ${#prompt} chars"
  exit 0
fi

tmp="${TMPDIR:-/tmp}"
# 启动前清扫：临时目录下超过 7 天的 engram-review-* 残留一律删掉，防止无限堆积。
find "$tmp" -maxdepth 1 -name 'engram-review-*' -type f -mtime +7 -delete 2>/dev/null

stamp="$$-$RANDOM"
prompt_file="$tmp/engram-review-$stamp.txt"
out_file="$tmp/engram-review-out-$stamp.txt"
err_file="$tmp/engram-review-err-$stamp.txt"
printf '%s' "$prompt" > "$prompt_file" || exit 0

# 完全脱管启动（nohup + &），hook 立即返回、绝不阻塞会话收尾/启动。
# prompt 经环境变量传入子 shell，作为单个参数交给 `kimi -p`（已实测 kimi -p 不读 stdin）。
# $RV_MODEL 故意不加引号：为空时自然消失、为 "-m <别名>" 时分成两个参数。
# 复盘者退出后把退出码 + out/err 尾部若干行追进 hook.log，让静默失败可观测。
RV_CLI="$kimi" RV_MODEL="$model_args" RV_PROMPT="$prompt_file" RV_OUT="$out_file" RV_ERR="$err_file" \
RV_LOG="$hook_log" \
ENGRAM_REVIEWER=1 nohup bash -c '
  prompt="$(cat "$RV_PROMPT" 2>/dev/null)"
  "$RV_CLI" -p $RV_MODEL "$prompt" > "$RV_OUT" 2> "$RV_ERR"
  ec=$?
  mkdir -p "$(dirname "$RV_LOG")" 2>/dev/null
  {
    printf "[%s] engram reviewer done exit=%s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$ec"
    tail -n 5 "$RV_OUT" 2>/dev/null | sed "s/^/  out| /"
    tail -n 5 "$RV_ERR" 2>/dev/null | sed "s/^/  err| /"
    if [ "$ec" -ne 0 ]; then
      printf "  diag| 复盘者非零退出——常见原因：未登录/模型别名不存在/代理缺失；可查 out|err| 行或用 ENGRAM_REVIEWER_PROXY 指定代理\n"
    fi
  } >> "$RV_LOG" 2>/dev/null
' >/dev/null 2>&1 &
exit 0
