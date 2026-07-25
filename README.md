# engram-kimi

> The **Kimi Code adapter** for [Engram](https://github.com/jimhy/engram), a human-like layered long-term memory system. **Layered, forgetful, self-consolidating.** Injects relevant memories on the first prompt of each session, runs an independent reviewer at session end, and lets the agent recall on demand via a skill. Single Rust binary, zero dependencies, no vector database, **shares the same memory stores with the Claude Code / Codex / opencode adapters**.

[中文](./README.zh-CN.md) | **English**

---

## Why

Most agent "memory" stuffs everything into a vector store and force-feeds chunks back into the context — token-hungry, noisy, awkward. Engram mimics human memory instead:

- **Store summaries, not details.** Each memory = a one-line **cue** + a **pointer** to ground truth (`file:line`, doc, URL). Recall the cue, then follow the pointer when details are needed — **verify, don't reconstruct**.
- **Store only the complement of artifacts.** Code is already the perfect detail store (`grep` finds everything). Engram keeps what code lacks: intent, decisions, dead ends, the "why".
- **Forget the noise.** Memories decay (ACT-R style) unless reinforced by real use; low-value ones sink out of the hot set. **Forgetting = demotion, not deletion.**

The result: a small, highly relevant **hot index** in context, plus a much larger searchable **cold store** — **with no vector database**.

## Install

Inside a Kimi Code session:

```
/plugins install https://github.com/jimhy/engram-kimi
```

Then `/reload` (or start a new session). Uninstall: `/plugins remove engram`.

## What you get

| Kimi Code mechanism | What it does |
|---|---|
| `UserPromptSubmit` hook | Injects the **hot index** (relevant memories) via `engram hot-index` — on the first prompt of a session and on scope switches, silent otherwise (per-session gating); also registers the active session for crash catch-up |
| `SessionStart` hook | **Catches up** any consolidation a previous session left unfinished (leftover pendings, orphan sessions after a hard kill) |
| `SessionEnd` hook | Launches an **independent** headless `kimi -p` reviewer that consolidates only the **increment since the last watermark** (write new, promote/demote, supersede, merge) |
| engram **skill** | Recall-first: when asked "did we handle X before / what is this project / what's left", the agent checks memory before scanning code |
| `/engram:recall` `/engram:list` `/engram:status` `/engram:render` `/engram:web` `/engram:root` commands | Manual recall / inspect / preview the hot index / web dashboard / mark a workspace root |

The stores are **shared with the Claude Code / Codex / opencode adapters** (`~/.engram/general.redb` + per-project `<project>/.engram/engram.redb`) — memories flow between the CLIs.

## How it works

Memory is **layered**, like the brain's:

| Layer | Role | Decay |
|------|------|------|
| **L1** | "Subconscious" — core identity / preferences | barely (high floor) |
| **L2** | Important | slow |
| **L3** | Ordinary | medium |
| **L4** | Project-scoped, in `<project>/.engram/engram.redb` | anchored by the `.engram/` marker |

- **activation = importance + recency + frequency** (ACT-R base-level), with per-layer floors so L1 holds.
- **Promotion is earned by activation; demotion has floors and grace periods** — new and important memories are not killed prematurely.
- **Consolidation** runs at session end in an **independent** `kimi -p` reviewer reading the transcript, so "what was truly used and worth keeping" is not graded by the worker itself.

See the [Chinese README](./README.zh-CN.md) for the per-layer content rules (or `plugin/skills/engram/SKILL.md` for the full agent-facing rubric).

## Where memories live

- **General store** (cross-project L1-3): `~/.engram/general.redb` (auto-created)
- **Project stores** (L4): `<project>/.engram/engram.redb`
- **Kimi-only consolidation ledger** (watermark / pending / registration / logs): `~/.engram/kimi/` — isolated from the other adapters' ledgers so they never fight over progress

Storage is **[redb](https://github.com/cberner/redb)** (embedded, single-file, ACID) — no server, no external database.

## Layout

```
kimi.plugin.json                   manifest (skills + commands + hooks; must sit at the repo
                                   root — kimi's installer only detects root-level manifests)
scripts/                           kimi-{session-start,prompt-hotindex,session-end,launch-reviewer}.{ps1,sh}
                                   + reviewer-prompt.md + reviewer-log.ps1
skills/engram/SKILL.md             engram agent interface + judgment rubric
commands/                          /engram:{recall,list,status,render,web,root}
bin/                               engine binaries for four platforms
```

## Platforms

Each hook `command` is a two-platform compound: `bash ./scripts/x.sh 2>/dev/null || powershell ... x.ps1` —

- **macOS / Linux**: runs via `sh` into the bash branch (`.sh`, LF enforced by `.gitattributes`).
- **Windows**: kimi runs hooks through `cmd`, where the `2>/dev/null` redirect always fails → falls through to the PowerShell branch (`.ps1`). If the hook shell ever becomes bash (Git Bash / msys), the `.sh` scripts detect MSYS/Cygwin and delegate to the same-named `.ps1` — on Windows behavior always converges on the PowerShell implementation.

## Differences from the Claude Code adapter (measured on kimi)

- **Injection rides `UserPromptSubmit`, not `SessionStart`**: kimi's `SessionStart` is observation-only (stdout never reaches the context, verified by experiment); only `UserPromptSubmit` stdout is appended. So `SessionStart` does silent bookkeeping (catch-up) and the hot index lands on the first prompt, gated per session to avoid re-injecting every prompt.
- **`SessionEnd`, not `Stop`**: kimi has a real `SessionEnd` (matcher `exit`), same shape as the Claude main plugin; a too-small increment still drops its pending and is consolidated by the next `SessionStart` catch-up.
- **Reviewing via `kimi -p`** (instead of `claude -p`): `kimi -p` does **not** read the prompt from stdin (`-p -` treats `-` as the literal prompt), so the prompt is passed as a single command-line argument; print mode auto-approves tool calls, no allowlist flags needed.
- **Transcript is `wire.jsonl`**: hook stdin carries no `transcript_path`; scripts resolve it from `session_id` via `session_index.jsonl`'s `sessionDir` (glob `sessions/*/<sid>/agents/main/wire.jsonl` fallback), and the launcher appends a format note to the review prompt.
- **Hooks only fire in interactive sessions**: `kimi -p` (print mode) fires no lifecycle hooks, so the reviewer cannot recurse; the `ENGRAM_REVIEWER=1` guard stays as a safety net.

## Configuration

- `ENGRAM_BIN` — override the engine binary path (defaults to the platform binary bundled in `bin/`).
- `ENGRAM_REVIEWER_KIMI` — the kimi executable used to launch the reviewer (default `kimi`).
- `ENGRAM_REVIEWER_MODEL` — model alias override for the headless reviewer (`kimi -m <alias>`).
- `ENGRAM_REVIEWER_PROXY` — explicit proxy for the reviewer subprocess (otherwise derived from HTTPS_PROXY → ALL_PROXY → system proxy).
- `ENGRAM_HOOK_DRYRUN` — when `1`, the launcher only prints what it would run (debugging).

## License

Apache License 2.0 — see [LICENSE](./LICENSE).
