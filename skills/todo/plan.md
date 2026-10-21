# TODO skill — plan and execute

Lifecycle: **open → plan → busy → done** (or skipped). A short item that turns
out to be complex or to have open questions goes through `plan/` first. There
is no separate plan document: the item file itself is the plan. Planning turns
a short `<date>.<type>.<slug>.md` into a complete one, and execution works from
it. Both steps are heavy reasoning work — if this session runs on a small
model, suggest `/model opus` first.

`todo.sh path <n>` gives the item's file path; `todo.sh show <n>` prints it.
`<n>` is the label from the listing: `3` (open), `P2` (planning), `B1` (busy).
After `plan`/`execute` the item gets a new label — the script prints it
(`Planning (now P1)`, `Started (now B1)`); use that one from then on.

---

## `/todo <n> plan` — plan the item

1. **Move it:** `todo.sh plan <n>` (open or busy → `plan/`, logs it). The
   output gives the new path — everything below is edits to that file.
2. **Read the item** as it stands: Description, Analysis, links, images.
3. **Research.**
   - Codebase: similar features and patterns, files to reference, conventions
     to follow, how tests are written here (that decides the validation gates).
   - External: library docs (specific URLs), implementation examples, known
     pitfalls. Web search is available; put URLs in the plan.
   - As you go, note every ambiguity, missing decision or assumption that
     would lower one-pass success: patterns to mirror, integration details,
     data shapes, edge cases, validation expectations, scope boundaries.
4. **Confidence gate — before writing the plan.** Rate one-pass
   implementation confidence 1–10. Target ≥ 9 (the user can pass a lower
   number: `/todo 3 plan confidence 8`). Below target, resolve the gaps
   **now** with `AskUserQuestion`: batch the highest-impact questions (up to 4
   per call), each targeting one specific gap, with concrete options drawn
   from your research. When an option needs more than a sentence to judge — a
   code pattern, a data shape, a UI sketch — put that in the option's
   `preview` so the user sees it in the side pane while scrolling. Fold the
   answers in, re-rate, repeat until you clear the target or further
   questions would no longer raise it (say so if you stop there). Do not
   write the plan first and ask later.
5. **Write the plan into the item file.**
   - `## Description`: sharpen it with what you learned — goal, why (business
     value, who it's for), what (user-visible behavior and technical
     requirements), success criteria as a checklist. Keep the user's original
     wording where it was already precise.
   - `## Analysis`: this is the plan proper. Use these subsections, from
     `references/prp_base.md` (relative to this skill's folder):
     - **Context & references** — documentation URLs with the specific
       sections that matter; the files in this codebase to mirror and why;
       real code snippets as patterns to follow.
     - **Gotchas** — library quirks, version issues, project conventions,
       things that bit similar work before.
     - **Implementation blueprint** — pseudocode for the approach, the files
       to touch, error handling, and the **tasks in execution order**.
     - **Validation gates** — commands that run as-is for this project's
       stack (Laravel: `vendor/bin/pint`, `php artisan test`; see the
       `references/validation/*.md` files for others).
     - **Decisions** — the answers the user gave at the gate, so they are not
       re-asked later.
   - Leave `## Solution` empty; that's for execution.
6. **Check** the plan: all needed context in the file, gates executable,
   existing patterns referenced, a clear ordered path, error handling covered.
7. **Report** the final confidence score and a Status Log line
   (`- <date>: plan written, confidence N/10`). If the score is below target,
   name the external blocker rather than shipping a low score quietly. Offer
   `/todo <n> execute`.

---

## `/todo <n> execute` — implement it

Also triggered by `/todo <n>` on a planned item (see reference.md → "Picking
an item") and by `todo pick` in a terminal.

1. **Move it:** `todo.sh execute <n>` (open or planned → `busy/`). If it was
   never planned and is `complexity: medium|high`, read it first and, if it has
   open questions or touches many files, propose `/todo <n> plan` instead of
   pressing on — the user decides.
2. **Load.** Read the item fully. The Analysis section is the plan; follow it,
   and extend its research where it is thin. Do more codebase exploration and
   web searches as needed until you have everything.
3. **Plan the work.** Think hard before touching code. Break the blueprint's
   task list into concrete steps and track them with your task tool. Identify
   the existing patterns the plan points at and mirror them.
4. **Implement** every task, in the plan's order.
5. **Validate.** Run each validation gate from the plan. Fix failures and
   re-run until all pass. Use the plan's gotchas when something breaks.
6. **Review.** Gates catch mechanical problems; a review catches logic bugs.
   Run the `code-review` skill on the working-tree diff at the item's
   complexity as level: `low` → `low`, `medium` → `medium`, `high` → `high`
   (no `--comment`, nothing is posted). Fix every confirmed finding, then
   re-run the validation gates. A finding you judge wrong or out of scope stays
   unfixed — note it and why. Skip the review only when no code changed (docs
   or prose only) and say so.
7. **Complete.** Re-read the plan once more and check every requirement and
   success criterion is actually done; run the full validation suite a final
   time. Note anything you deliberately diverged from and why.
8. **Finish through the normal done flow** (reference.md → "Marking an item
   done"): `todo.sh done <n>`, write `## Solution` — what was done, any
   divergence from the plan, and what the review found: fixed, or left and
   why — then the framework validation gates and a short report.
