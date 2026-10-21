# TODO-md

A Claude plugin that keeps a project's TODO list as plain markdown files in
`docs/todo/`, one file per item, and drives the whole lifecycle from a `/todo`
skill: **open → plan → busy → done** (or skipped).

- **One file per item.** `docs/todo/<date>.<type>.<slug>.md` with YAML
  frontmatter (`title`, `type`, `urgency`, `complexity`, `term`, `category`,
  `status`, dates) and `## Description` / `## Analysis` / `## Solution` /
  `## Status Log` sections. Types: `bug`, `change`, `feature`, `chore`.
- **Generated listings.** Every `index.md` is a snapshot written by the script;
  nothing is hand-edited. Item numbers are never stored: busy items are `B1 B2…`,
  planned items `P1 P2…`, open items `1 2…`, recomputed on every listing.
- **Plan, then execute.** `/todo 3 plan` researches the item, asks you the open
  questions and writes the plan *into the item file* (there is no separate PRP
  document). `/todo P1 execute` implements from that plan, runs the validation
  gates and a code review, then writes up the Solution when the item is done.
- **Cross-project.** Every project that runs `/todo init` is registered in
  `~/.claude/state/todo-projects.tsv`. `/todo global` and `/todo busy --all`
  read across projects; a `/todo-dashboard` pane shows them live inside Claude
  Code; `todo web` serves a local web dashboard.
- **Framework validation rules** for Laravel, Python, Go and bash projects
  (`skills/todo/references/validation/`) are applied when an item is marked done.

## Install

```bash
claude plugin marketplace add pforret/todo-md
claude plugin install todo-md@todo-md
```

For development, run a session with the checkout loaded directly:

```bash
git clone https://github.com/pforret/todo-md ~/Code/todo-md
claude --plugin-dir ~/Code/todo-md
```

## Usage

In a Claude Code session, inside a project:

| Command | What it does |
|---|---|
| `/todo init` | create `docs/todo/` and register the project |
| `/todo` | show the open, planned and busy items |
| `/todo add bug the login form loses the email on error` | add an item |
| `/todo 1` · `/todo 1 plan` · `/todo P1 execute` · `/todo B1 done` | work an item through its lifecycle |
| `/todo 2 skip duplicate of 1` · `/todo 1 reopen` | skip and reopen |
| `/todo done` · `/todo done 2026-09` · `/todo skipped` | look back |
| `/todo global` · `/todo busy --all` | across all registered projects |
| `/todo-dashboard` | open the live cross-project pane (Claude Code only) |

While another skill already owns the bare `/todo` name, the plugin's skill is
reachable as `/todo-md:todo`.

### Terminal use

The engine is a single bash script, `skills/todo/scripts/todo.sh`, and works
without Claude too. Symlink it from a checkout:

```bash
ln -s ~/Code/todo-md/skills/todo/scripts/todo.sh ~/.local/bin/todo
todo index            # same listing as /todo
todo pick             # fzf picker that launches Claude on the chosen item
todo web              # local web dashboard on http://127.0.0.1:7474
todo help             # full command reference
```

If you installed through the marketplace, the script lives in the plugin cache
(`claude plugin list` shows the path); that path changes on every plugin update,
so prefer a checkout for the symlink.

## Requirements

- **bash 4 or newer.** macOS, Linux and WSL have it. On native Windows, install
  Git for Windows: Claude Code's Bash tool needs it anyway, and the script then
  runs under Git Bash. This is expected to work but has not been tested yet.
- Optional: `fzf` for `todo pick`, `python3` for `todo web` (standard library
  only), `claude` on the PATH for `todo pick`.
- `todo web install` (a launchd service that keeps the dashboard running from
  login on) and `todo web proxy` (Laravel Valet) are macOS-only. Re-run
  `todo web install` after a plugin update, since the service records the
  script's absolute path.

## Data and privacy

The plugin reads and writes `docs/todo/` inside your projects and the registry
file `~/.claude/state/todo-projects.tsv`. The web dashboard listens on
127.0.0.1 only. Nothing is sent anywhere.

## License

MIT, see [LICENSE](LICENSE).
