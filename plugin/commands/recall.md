---
description: 在 engram 记忆库里按关键词检索（冷库、热库都搜）
---

# /engram:recall

用 engram 检索记忆。用户的查询在 `$ARGUMENTS`。

**先定位引擎二进制**（用户 PATH 里一般没有 `engram`）：在 `$KIMI_CODE_HOME/plugins/managed/engram/bin/`（`KIMI_CODE_HOME` 缺省为 `~/.kimi-code/`）下按平台选 `engram-windows-x86_64.exe` / `engram-macos-aarch64` / `engram-macos-x86_64` / `engram-linux-x86_64`。下文命令里的 `engram` 都指这个绝对路径（`ENGRAM_BIN` 环境变量已设定时优先用它）。

**再锚定当前项目作用域**（引擎从当前目录向上找 `.engram/` 锚点）：

```bash
engram resolve --format json
```

拿到 `general_db` / `project_db` / `project_name` 后检索（含空格的路径加引号）：

```bash
engram recall --general-db "<general_db>" --project-db "<project_name>=<project_db>" --query "$ARGUMENTS"
```

- 默认连冷库一起搜（recall 本就是"我们以前是否处理过 X"）。

展示候选（命中分 score、层级、状态、cue、指针）。提醒用户：拿到候选后**顺指针去查 ground truth**，不要凭印象。
