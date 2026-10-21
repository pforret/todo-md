---
name: todo
description: Unified TODO management for a project's docs/todo — init, list, add, plan (research + questions, the item file becomes the plan), execute (implement from it), done, skip, reopen, and a cross-project registry. Use whenever the user runs /todo (with any arguments), asks to see, add to, or update a project's TODO list, bugs, features, or planned work, asks to plan or implement an item (formerly /generate-prp and /execute-prp), or says "mark as done" / "that's done" after working on a TODO item (the done step includes writing up the Solution).
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/todo.sh *), Bash("${CLAUDE_SKILL_DIR}/scripts/todo.sh" *)
---

# TODO

All mechanics live in `${CLAUDE_SKILL_DIR}/scripts/todo.sh` — run it with Bash
(quote the path: `"${CLAUDE_SKILL_DIR}/scripts/todo.sh" index`) and show its
output. Everywhere this skill's files say `todo.sh`, that is the path to run. The
supporting files (`reference.md`, `plan.md`, `references/...`) live in
`${CLAUDE_SKILL_DIR}`. Never hand-edit files under `docs/todo/` except an item's
prose sections. `todo.sh help` is the full command reference.

**Model:** `docs/todo/` holds open items as `<date>.<type>.<slug>.md` files with
YAML frontmatter; `plan/`, `busy/`, `done/YYYY-MM/`, `skipped/` hold the rest,
images live in `assets/`. Lifecycle: open → (plan →) busy → done | skipped. A
planned item's file *is* its plan — there is no separate PRP document. Types: `bug`
(broken), `change` (works, small tweak), `feature` (new), `chore` (internal,
nothing a user sees). Term: `short` (⚡ needed soon — default) or `long` (🔭
"wouldn't it be nice if one day..."); listings put every short-term item before
the long-term ones. Item numbers are never
stored — they are the row position in the last listing, recomputed each call, so
act on a number right after the listing that printed it. Active items are
numbered per group: busy `B1 B2…`, planning `P1 P2…`, open `1 2…`. `<n>` below
is any of those (case-insensitive); a bare number only ever means an open item.
Always pass the label exactly as listed — `todo.sh P1 …`, never `todo.sh 1` for P1. All `index.md` files
are generated snapshots; don't edit them.

## First: detect

Except for `/todo` alone and `/todo help`, run `todo.sh detect` first.
`missing` → suggest `/todo init` and stop. `legacy` → old `bugs/features/planned`
layout present; suggest `/todo migrate` (dry run) before anything else, since
mutating commands overwrite the old `index.md` (user may still opt out).
`ready` → proceed.

## Dispatch

Read `reference.md` in this skill folder for the rows marked ★, only for that
section. Planning and executing an item is in `plan.md`.

| User says | Run |
|---|---|
| `/todo` alone | `todo.sh` — print verbatim, nothing else |
| `/todo help` | `todo.sh help` — print verbatim |
| `/todo index` / `i` / `list` | `todo.sh index` |
| `/todo plan` (no number) · `busy` · `urgent` · `short` · `long` · `skipped` | same subcommand |
| `/todo done` (no number) · `done 2026-03` · `done all` | `todo.sh done [month\|all]` — this month by default |
| `/todo <n>` | `todo.sh show <n>`, then ★ Picking an item — ends in execute, or a proposal to plan first |
| `/todo <n> plan`, "plan this first", "this has open questions" | `plan.md` → plan (move to `plan/`, research, questions, write the plan into the item) |
| `/todo <n> execute` · `/todo <n> start`, "implement it" | `plan.md` → execute (move to `busy/`, implement from the item, code review, then the done flow) |
| `/todo <n> done`, "mark as done", "that's done" | ★ Marking an item done — the Solution write-up is your job |
| `/todo <n> skip [reason]` | ★ Skipping and reopening |
| `/todo <n> reopen` · `/todo <n> settype <type>` · `/todo <n> set <key> <value>` | ★ Skipping and reopening |
| `/todo add ...` | ★ Adding an item |
| `/todo pick` | ★ Interactive pick — index + `AskUserQuestion`; never run `todo.sh pick` from a tool call |
| `/todo init` · `migrate` | ★ Init and migration — migrate is a judgment task you drive, not a one-shot script run |
| `/todo global` · `busy --all` · `urgent --all` · `web` | ★ Cross-project |

Every subcommand takes an explicit `dir` as last argument for another project;
default is `docs/todo` in the current directory.
