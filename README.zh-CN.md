# engram-kimi

> [Engram](https://github.com/jimhy/engram) 仿人脑分层长期记忆系统的 **Kimi Code 适配器**。**分层、会遗忘、自动巩固。** 每条会话首条 prompt 注入相关记忆、会话结束自动复盘巩固、按需经 skill 主动检索。单 Rust 二进制、零依赖、不用向量数据库、**与 Claude Code / Codex / opencode 版共用记忆库**。

**中文** | [English](./README.md)

---

## 为什么

大多数 AI agent 的"记忆"是把一切塞进向量库、再把切片硬塞回上下文——费 token、噪声大、用起来别扭。Engram 反其道而行，照人类记忆的方式来：

- **记总结，不记细节。** 每条记忆 = 一句话**线索（cue）** + 一个指向 ground truth 的**指针**（`文件:行`、文档、URL）。先回忆线索，需要细节时顺指针去查——**是验证，不是脑补重建**。
- **只存"产物的补集"。** 代码本身就是最完美的细节存储（`grep` 就能找到）。Engram 只存代码里**没有**的：意图、决策、走过的死路、"为什么"。
- **遗忘噪声。** 记忆随时间衰减（ACT-R 式），除非被真实使用加固；低价值的会降级出热集。**遗忘 = 降级，不是删除。**

结果：上下文里始终是一小撮**高相关的"热索引"**，外加一个大得多、可检索的**冷库**——**而且不需要向量数据库**。

## 安装

在 Kimi Code 会话里：

```
/plugins install https://github.com/jimhy/engram-kimi
```

然后 `/reload`（或开新会话）生效。卸载：`/plugins remove engram`。

## 你会得到什么

| Kimi Code 机制 | 作用 |
|---|---|
| `UserPromptSubmit` hook | 经 `engram hot-index` 把**热索引**（相关记忆）按需注入上下文——每会话首条 prompt / 作用域切换时注入，其余静默（按会话门控，不重复刷上下文）；顺带做活跃会话登记（崩溃补漏用） |
| `SessionStart` hook | **补跑**上次会话未完成的巩固（残留 pending 或强杀留下的孤儿会话） |
| `SessionEnd` hook | 起一个**独立**的无头 `kimi -p` 复盘者，只巩固**自上次水位线以来的增量**（写入新记忆、升降级、标记取代、合并） |
| engram **skill** | recall-first：被问"以前处理过 X 吗 / 这项目是什么 / 还剩什么没做完"时，agent 先查记忆再翻代码 |
| `/engram:recall` `/engram:list` `/engram:status` `/engram:render` `/engram:web` `/engram:root` 命令 | 手动检索 / 检视 / 预览热索引 / 网页看板 / 设项目管理目录 |

记忆库与 **Claude Code / Codex / opencode 版共用**（`~/.engram/general.redb` + 各项目 `<项目>/.engram/engram.redb`），几个 CLI 的记忆互通。

## 工作原理

记忆**分层**，仿人脑：

| 层级 | 角色 | 衰减 |
|------|------|------|
| **L1** | "潜意识"——核心身份 / 偏好 | 几乎不忘（高 floor） |
| **L2** | 重要 | 慢 |
| **L3** | 普通 | 中等 |
| **L4** | 项目级，存于 `<项目>/.engram/engram.redb` | 项目作用域，按 `.engram/` 锚点定位 |

- **activation = 重要度 + 近因 + 频率**（ACT-R base-level），每层带 floor，让 L1 站得住。
- **爬升要靠挣来的活跃度；下跌有 floor 和宽限期兜底**——新记忆、重要记忆不会被过早杀掉。
- **巩固**在会话结束由一个**独立**的 `kimi -p` 复盘者读转录完成，所以"哪些真被用到、值得留"的判断不会自卖自夸。

### 每层存什么

一条记忆值不值得留，看它**能不能从代码 / 文档 / git 轻易找回**——engram 只存 artifact 的**补集**（意图、为什么、试过的死路、决策、未完成的开口），提炼成一句话 cue + 一个指向 ground truth 的指针。

**通用 —— 跨项目，存公共库（`~/.engram/general.redb`）：**
- **L1**——核心身份 & 常驻全局规矩：你是谁、怎么称呼、用什么语言、雷打不动的全局约定。极少、几乎不忘。
- **L2**——跨项目通用的重要知识（某工具的坑、长期偏好）。
- **L3**——一般、易忘的通用笔记。

**项目级 —— L4，存该项目的库（`<项目>/.engram/engram.redb`）：**
- **L4.1**——项目铁律：**本仓库**不可违反的约定 / 禁忌，来自你的"永远 / 绝不"指令或踩坑确立。**不是**照抄 AGENTS.md / lint 配置（那些是会被自动加载的 artifact）；L4.1 只存它们**没写**的隐性铁律。
- **L4.2**——持久项目知识：这项目是干嘛的、**架构 / 模块心智地图**（各部分干嘛、为什么这么分——提炼版，不是 `ls` 罗列）、已定型 / 已辩论的决策（选了什么、否了什么及原因——免得后续会话重提死方案）。
- **L4.3**——快衰减层：重要度低、时效短的记忆（当前进度、短命开口、可交接的活自然落这里）。层级不绑定内容类型——重要的长期开口按重要度落更高层；做完 / 失效核实后即删。

> 黄金法则：**只存提炼的心智模型，绝不存单条 `grep` / `ls` 就能拿到的东西。** 文件位置放在指针里，不放进 cue。

## 记忆存哪

- **公共库**（跨项目 L1-3）：`~/.engram/general.redb`（首次自动建）
- **项目库**（L4）：`<项目>/.engram/engram.redb`（随项目走）
- **kimi 专属巩固账本**（水位线 / pending / 登记 / 日志）：`~/.engram/kimi/`——与其他适配器的账本隔离，互不抢进度

存储用 **[redb](https://github.com/cberner/redb)**（嵌入式、单文件、ACID）——无服务、无外部数据库。**和 Claude Code / Codex / opencode 版用的是同一套库**，几个 CLI 的记忆互通。

## 结构

```
kimi.plugin.json                   manifest（skills + commands + hooks；须在仓库根，kimi 安装器只认根级 manifest）
scripts/                           kimi-{session-start,prompt-hotindex,session-end,launch-reviewer}.{ps1,sh}
                                   + reviewer-prompt.md + reviewer-log.ps1
skills/engram/SKILL.md             engram agent 接口 + 判定 rubric
commands/                          /engram:{recall,list,status,render,web,root}
bin/                               四平台引擎二进制
```

## 平台

hook `command` 是一条双平台复合命令：`bash ./scripts/x.sh 2>/dev/null || powershell ... x.ps1`——

- **macOS / Linux**：经 `sh` 走 bash 分支（`.sh`，LF 行尾由 `.gitattributes` 保证）。
- **Windows**：kimi 的 hook 经 `cmd` 执行，`2>/dev/null` 重定向在 cmd 下必然失败 → 自动落到 PowerShell 分支（`.ps1`）。若 hook shell 某天变成 bash（Git Bash / msys），`.sh` 开头也会检测 MSYS/Cygwin 并转调同名 `.ps1`——Windows 上行为始终统一走 PowerShell 实现。

## 与 Claude Code 适配器的差异（kimi 平台实测结论）

- **注入走 `UserPromptSubmit` 而非 `SessionStart`**：kimi 的 `SessionStart` 是纯观察事件（stdout 不进上下文），只有 `UserPromptSubmit` 的 stdout 会被追加进上下文。因此 `SessionStart` 只做静默杂务（补跑），热索引在首条 prompt 时注入，并按会话门控避免每条 prompt 重复注入。
- **用 `SessionEnd` 而非 `Stop`**：kimi 有真正的 `SessionEnd`（matcher `exit`），与 Claude 主插件同构；增量不够也落 pending，攒到下次 `SessionStart` 补跑。
- **复盘用 `kimi -p`**（而非 `claude -p`）：`kimi -p` **不从 stdin 读 prompt**（`-p -` 会把 `-` 当字面 prompt），prompt 作为单个命令行参数传入；非交互模式 auto 权限自动批准工具调用，无需 allowlist 参数。
- **转录是 `wire.jsonl`**：hook stdin 不带 `transcript_path`，脚本由 `session_id` 查 `session_index.jsonl` 的 `sessionDir`（glob `sessions/*/<sid>/agents/main/wire.jsonl` 兜底），格式说明由启动器追加进复盘 prompt。
- **hook 只在交互式会话触发**：`kimi -p`（非交互）不触发任何会话生命周期 hook，复盘者天然不递归；`ENGRAM_REVIEWER=1` 守卫仍保留作保险。

## 配置

- `ENGRAM_BIN` —— 覆盖引擎二进制路径（默认用插件自带 `bin/` 下按平台选的）。
- `ENGRAM_REVIEWER_KIMI` —— 复盘者启动的 kimi 可执行文件（默认 `kimi`）。
- `ENGRAM_REVIEWER_MODEL` —— 无头复盘者的模型别名覆盖（`kimi -m <别名>`）。
- `ENGRAM_REVIEWER_PROXY` —— 复盘者子进程显式代理（缺省按 HTTPS_PROXY → ALL_PROXY → 系统代理派生）。
- `ENGRAM_HOOK_DRYRUN` —— 设为 `1` 时启动器只打印将执行的复盘参数，不真正启动（调试用）。

## 许可证

Apache License 2.0 —— 见 [LICENSE](./LICENSE)。
