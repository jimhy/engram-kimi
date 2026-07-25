---
description: 预览 engram 会注入到会话上下文的"热索引"
---

# /engram:render

**先定位引擎二进制**（用户 PATH 里一般没有 `engram`）：在 `$KIMI_CODE_HOME/plugins/managed/engram/bin/`（`KIMI_CODE_HOME` 缺省为 `~/.kimi-code/`）下按平台选 `engram-windows-x86_64.exe` / `engram-macos-aarch64` / `engram-macos-x86_64` / `engram-linux-x86_64`。下文命令里的 `engram` 都指这个绝对路径（`ENGRAM_BIN` 环境变量已设定时优先用它）。

```bash
engram hot-index --workspace-root "$PWD"
```

展示渲染出的热索引——**这就是 UserPromptSubmit hook 会在每条 prompt 前按需注入进会话的内容**（公共 L1-3 + 当前目录及活跃子项目的 L4）。用于核对"会话到底看到了什么记忆"。
