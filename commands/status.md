---
description: 查看 engram 记忆系统概况（各层条数 / 项目 / 冷库 / 墓碑）
---

# /engram:status

**先定位引擎二进制**（用户 PATH 里一般没有 `engram`）：在 `$KIMI_CODE_HOME/plugins/managed/engram/bin/`（`KIMI_CODE_HOME` 缺省为 `~/.kimi-code/`）下按平台选 `engram-windows-x86_64.exe` / `engram-macos-aarch64` / `engram-macos-x86_64` / `engram-linux-x86_64`。下文命令里的 `engram` 都指这个绝对路径（`ENGRAM_BIN` 环境变量已设定时优先用它）。

```bash
engram status --general-db "$HOME/.engram/general.redb" --format full
```

把概况展示给用户：active 总数、通用层 L1/L2/L3 条数、各项目 L4、cold / superseded / tombstone 计数。用于确认记忆系统在正常工作、库里有多少东西。
