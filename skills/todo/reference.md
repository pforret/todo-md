# TODO skill — detailed procedures

Read only the section you need. SKILL.md tells you which one.

## Adding an item

`/todo add <description>` or a bare `/todo add`. Ask only for what's missing;
don't re-ask for things already given:

- **title** — required.
- **type** — `bug` = broken, it should already work this way. `change` = it
  works, but tweak something small (copy, color, position, type, ...).
  `feature` = genuinely new functionality. `chore` = internal work with no
  user-visible outcome: refactoring, dependency/framework upgrades, tech debt,
  tests, CI/tooling, docs. Infer from phrasing when obvious ("broken",
  "doesn't work" → bug; "should say/look/be" → change; "add", "support for" →
  feature; "refactor", "upgrade", "clean up", "add tests for", "migrate to" →
  chore); otherwise ask.
- **urgency** — `essential`/`useful`/`nice-to-have`. Default `useful` if not
  said and not obviously essential.
- **complexity** — `low`/`medium`/`high`. Default `low`.
- **term** — `short` = needed soon ("asap", "this sprint", "before the
  release"); `long` = "wouldn't it be nice if one day we could...". Default
  `short`. Infer `long` from phrasing like "one day", "someday", "eventually",
  "in the future", "long term", "nice to have at some point"; otherwise don't
  ask, just default. Long-term items sort below the short-term ones in every
  listing (⚡ vs 🔭) and `/todo short` / `/todo long` filter on it.
- **category** — which part of the stack. Free text, not validated, but prefer
  one of these so lists stay consistent: `front-end`, `back-end`, `admin`
  (Nova / back-office screens), `database` (migrations, imports, data
  cleanups, queries), `api` only if the project is itself an API, `tests`,
  `sysadmin` (deploy, servers, monitoring), `security` (auth, permissions,
  secrets, rate limits), `performance` (N+1, caching, queues), `docs`,
  `multimedia` (ffmpeg, images, audio/video). Default `general`.

Then:
```
todo.sh add --type=<type> --title="<title>" --urgency=<urgency> \
  --complexity=<complexity> --term=<term> --category=<category>
```
The created file has `## Description`/`## Analysis`/`## Solution` stubs — fill
in `## Description` from what the user told you (don't leave the placeholder).

## Picking an item

`/todo <n>` shows the item labelled `<n>` (`3`, `P2`, `B1`) in the most recent listing. If
no listing was shown yet this turn, run `todo.sh index` first, then
`todo.sh show <n>`. Picking an item means starting to work on it, so after
showing it decide the next step from what you see:
- **Planned** (`status: plan`, Analysis filled in) or **busy** → go to
  `plan.md` → execute.
- **Open and clearly simple** (low complexity, no open questions) → `plan.md`
  → execute as well: move it to busy and implement.
- **Open but complex** (`complexity: medium|high`, or the Description leaves
  real questions, or it touches many files) → say so and propose planning
  first: "This has open questions / is multi-step — plan it first
  (`/todo <n> plan`)?" On yes, `plan.md` → plan. On no, execute.
- Suggest an approach from `category`: front-end → UI/UX patterns, back-end →
  API/database patterns, tests → the project's test framework, sysadmin →
  deployment/ops.

## Planning

Complex or high-impact items go through `plan/` before any code. The item's
own file becomes the plan — a short item grows into a complete one with a
sharpened Description and an Analysis holding context, blueprint, ordered
tasks and validation gates. Listings mark planned items 📋. Both steps are in
`plan.md`: `/todo <n> plan` and `/todo <n> execute`.

`todo.sh start`/`execute` prints a hint when an open `complexity: high` item is
started without planning; it's a hint, not a gate — if the item turns out
simpler than it looked, skip planning and say why in `## Analysis`.

## Marking an item done

This is the step where the item's write-up gets finished. The script only
moves the file and stamps the date; the prose is your job. Do these in order:

1. **Identify the item.** With `/todo <n> done`, `<n>` refers to the most
   recent listing. With a bare "mark as done" / "that's done" after you've been
   working on an item this session, it's the item you picked earlier — run
   `todo.sh index`, find it by title/filename in the fresh numbering, and use
   that number. If it's genuinely ambiguous, show the index and ask.
2. **Move it:** `todo.sh done <n>`. The output gives the new path under
   `done/` — edit that file, not the old location.
3. **Write `## Solution`** in the moved file, replacing the `_TODO_`
   placeholder, from what actually happened in this session: what was changed
   and why, files/functions touched, commits or PR if any, trade-offs or
   decisions made, and anything deliberately left out or deferred. Be concrete
   and honest — if tests failed or a part was skipped, say so; this file is the
   record someone reads months later. If `## Description` or `## Analysis`
   are still placeholders, fill them from context too rather than leaving
   stubs behind.
4. **Run the framework validation gates** for this project and report the
   result. Detect the framework and load the matching file (paths relative to
   this skill's folder):
   - Laravel: `references/validation/laravel.md`
   - Python: `references/validation/python.md`
   - Go: `references/validation/golang.md`
   - Bash: `references/validation/bash.md`
   If something fails, say so and don't paper over it — the item can stay done
   with the failure noted in `## Solution`, or the user can reopen it; that's
   their call.
5. Confirm in one or two lines: what was completed, and the path of the
   detail file.

## Skipping and reopening

- **Skip**: needs a reason from `duplicate`, `wontfix`, `superseded`,
  `cannot-reproduce`, `out-of-scope`. If the user didn't give one, ask which
  fits. Then `todo.sh skip <n> <reason>`.
- **Reopen**: `todo.sh reopen <n>` (default pool `done`, this month) or
  `todo.sh reopen <n> --pool=skipped`. The number comes from `todo.sh done` or
  `todo.sh skipped`, not from the open/busy index. If the user listed an older
  month (`todo.sh done 2026-03`), pass the same `--month=2026-03` so the
  numbers line up; `--month=all` matches `todo.sh done all`.
- **Retype**: `todo.sh settype <n> <type>` (or a file path instead of `<n>`)
  changes the type in the frontmatter and in the filename.
- **Correct metadata**: `todo.sh set <n> urgency|complexity|term|category|milestone|title <value>`
  (or a file path). Prefer this over editing frontmatter by hand — it
  validates the value, logs the change and regenerates the snapshots.

## Done archive and assets

- `done/` is split per month: `done/YYYY-MM/`. `todo.sh done` shows this
  month by default; `todo.sh done 2026-03` or `todo.sh done all` for more. The
  per-month `index.md` files are the natural source for weekly updates, next
  to the legacy `done/DONE-YYYY-MM.md` summaries a migrated project may have.
- Images and attachments go in `docs/todo/assets/`; link them from an item as
  `assets/<file>` when the item is open. The script rewrites the `../` prefix
  every time an item moves folder, so never hand-adjust those links.

## Interactive pick

In a terminal, `todo pick` is an fzf picker that launches Claude on the chosen
item. It needs a TTY, so **never run `todo.sh pick` from a tool call** — it
would hang or fall through to a menu nobody can answer.

Inside Claude, `/todo pick` is the same thing done with `AskUserQuestion` in
its **side-by-side layout**: a vertical list of options on the left and, for
the highlighted option, a preview pane on the right. That layout appears as
soon as options carry a `preview` field (single-select only).

1. `todo.sh index` for fresh numbers, then `todo.sh brief <n>` for each item
   you will offer (one Bash call, several `brief`s).
2. One `AskUserQuestion`, single-select, `header: "Pick"`:
   - `label`: `<n> <title>` with `<n>` as listed — `B1`, `P2` or `3` (it is what the user will act on)
   - `description`: `type · urgency · complexity · term` and the status note
   - `preview`: the `brief` output verbatim — metadata line plus Description
   The tool takes at most 4 options, so page through the index in its order
   (short term first, then urgency): the first 3 items plus a 4th option **"next 3 →"** whose
   preview lists the titles of the following page. Repeat with the next page
   when chosen. The user can also type a number via the built-in "Other".
   Nothing open or busy: say so and offer `/todo add`.
3. Treat the answer as `/todo <n>` (→ "Picking an item" above): show it,
   then execute or propose planning.

Mention `todo pick` in the terminal once, as an aside, not as the answer.

## Init and migration

`/todo init` → `todo.sh init`. This also registers the project in the global
registry.

Migration is **your** job, with the script doing the mechanical bulk. Where an
item ends up can depend on what it says — a "planned" item that is really a
feature, a file in an unrecognised subfolder, an item sitting in an open folder
whose text says it was shipped months ago — and only reading it tells. Plan on
spending a few minutes per project, not seconds.

The procedure:

1. **Dry run:** `todo.sh migrate` (no `--apply`). Read the whole plan, not just
   the summary line. Note the `UNKNOWN` lines (unrecognised status subfolders,
   left in place) and the `planned→chore` list at the end.
2. **Sample before you commit.** Open a handful of items the plan puts in
   `open`: is any of them actually finished (a `**Status**: Done` line, a
   Solution section that's filled in)? Open the `planned→chore` ones: does a
   user see the result? Note what you'd change. Then show the user the plan
   plus your notes and ask to proceed.
3. **Apply the bulk:** `todo.sh migrate docs/todo --apply`.
4. **Fix the judgment cases** with the single-item tools, reading each file
   you touch. This includes the PRPs: migrate merges each legacy PRP into the
   item it can match by slug or by a `Source ticket:`/`TODO ref:` path, and
   turns every other PRP into an item of its own (`PRPs/done/` → done,
   `PRPs/` root → plan, type `feature`, complexity `high`). Read the
   "became items" list: is one of them really the plan for an existing item
   (compare titles; the PRP usually says)? Then move its `### Plan` block
   into that item by hand and delete the new file. Retype the rest as needed.
   For a PRP left in place, `todo.sh import-prp <prp> --into=<item>` or
   `todo.sh import-prp <prp> --status=done|plan --type=…` does one at a time.
   - wrong type → `todo.sh settype <file> feature|change|chore|bug`
   - wrong urgency/complexity/category → `todo.sh set <file> <key> <value>`
   - a file left in an `UNKNOWN` folder, or an "open" item that is really done
     → `todo.sh import <legacy-file> --status=done --finished=YYYY-MM-DD` (or
     `--status=skipped --reason=…`, `--status=open`), with `--type=` etc. as
     needed. `import` converts one legacy file the way migrate would, but with
     your choices. For an item migrate already converted into the wrong pool,
     the normal commands apply (`done <n>`, `skip <n> <reason>`).
5. **Verify:** `todo.sh index`, `todo.sh busy`, `todo.sh done all`,
   `todo.sh skipped`. Skim the titles — anything in the wrong list stands out.
   Check `git status` shows renames, not deletions plus additions.
6. **Report** what was moved, what you changed by hand and why, and anything
   you left for the user to decide.

What migrate does on `--apply` (it **moves** files; git will see renames):
- `index.md` / `README.md` / `DONE-*.md` inside `bugs/ features/ planned/` are
  lists, not items — deleted (they're regenerated).
- `<type>/x.md` → open; `<type>/done|fixed|completed/x.md` → `done/YYYY-MM/`
  (month of the file's last git commit); `<type>/ignored|cancelled/x.md` →
  `skipped/`.
- Images and other non-`.md` files → `assets/`, and image links in the moved
  items are rewritten to point there.
- Top-level `DONE-YYYY-MM.md` monthly summaries are kept (the user uses them
  for weekly updates) and moved into `done/`.
- `PRPs/*.md` are merged into their item's `## Analysis` (headings demoted one
  level under a `### Plan (migrated from …)` heading), or become items when
  no item matches. A not-yet-executed PRP whose item is still open moves that
  item to `plan/`. A finished PRP whose item is not done is listed for you to
  check.
- Emptied legacy folders are removed, so `detect` reports `ready` afterwards.

Tags are best-effort: from the old `index.md` line when it links to the file,
else from `**Severity**`/`**Priority**` lines in the item's header, else
`useful`/`medium`/`general`.

The `planned→chore` list deserves special care: the old `planned` bucket mixed
real chores with user-facing work, so expect to retype some of them.

## Cross-project

The registry at `~/.claude/state/todo-projects.tsv` is maintained automatically
by `init`/`migrate` (and by `register`, if you ever need to re-add a project by
hand). Cross-project views:
- `/todo global` → `todo.sh global` (open/busy counts per project)
- `/todo busy --all` / "what's in progress everywhere" → `todo.sh global busy`
- `/todo urgent --all` / "what's essential everywhere" → `todo.sh global urgent`
- `/todo web` / "open the todo dashboard" → tell the user to run `todo web` in a
  real terminal (it is a long-running server: `scripts/todo-web.py` inside this
  skill's folder, next to `todo.sh`; stdlib
  Python, http://127.0.0.1:7474, `--port=N`, `--no-open`, `--json` to dump the
  scan). `/` shows the active items (busy + plan by default, open on request)
  with project / type / urgency / term / category filters, a per-project chart and a
  detail drawer per item; `/history/` shows done + skipped items and the
  finished-per-month chart. Never start it from a tool call that blocks.
  `todo web install` registers a macOS launchd LaunchAgent (`com.pforret.todo-web`)
  so the server runs from login on; `status` / `restart` / `log` / `uninstall`
  manage it. With the service up, `todo web` just opens the browser.
  `todo web proxy` adds a Laravel Valet proxy so http://todolist.test serves it
  (needs sudo → the user runs it themselves in a terminal).
