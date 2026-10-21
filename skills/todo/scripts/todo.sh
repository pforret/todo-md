#!/usr/bin/env bash
# todo.sh — engine behind the /todo skill.
# One flat docs/todo/ folder per project, with busy/ done/ skipped/ subfolders.
# Every list is generated from YAML frontmatter in the item files — never hand-edited.
#
# Numbering: item numbers are NOT stored anywhere. They are the row's position
# in a freshly (re)computed, deterministically sorted list. A number is only
# meaningful right after the listing that produced it (e.g. run `todo.sh index`,
# then immediately act on the number it printed with `todo.sh <n> done`).
set -o errexit
set -o nounset
set -o pipefail

PROG=$(basename -- "$0")
readonly PROG
readonly REGISTRY="${TODO_REGISTRY:-$HOME/.claude/state/todo-projects.tsv}"
# internal row-format field separator (ASCII unit separator). NOT a tab:
# bash's `read` collapses consecutive plain-tab delimiters (tab is IFS
# whitespace), which silently eats empty fields like `finished`. This
# character is never whitespace, so every tool (awk/sort/cut/read) treats
# consecutive delimiters as a real empty field, never collapsing them.
readonly F=$'\x1f'
readonly VALID_TYPES="bug feature change chore"
readonly VALID_URGENCY="essential useful nice-to-have"
readonly VALID_COMPLEXITY="low medium high"
# term: short = needed soon (asap / this sprint), long = "one day it would be nice if"
readonly VALID_TERM="short long"
readonly VALID_SKIP_REASONS="duplicate wontfix superseded cannot-reproduce out-of-scope"

# ---------- generic helpers ----------

error() { printf 'Error: %s\n' "$*" >&2; }
die() { error "$*"; exit 1; }

in_list() {
  local needle="$1" haystack="$2" item
  for item in $haystack; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

today() { date +%Y-%m-%d; }

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# an active item label: 3 (open), P2 (planning), B1 (busy) — case-insensitive
is_label() { [[ "$1" =~ ^([0-9]+|[PpBb][0-9]+)$ ]]; }

# frontmatter: get a "key: value" field from the YAML block at the top of a file
fm_get() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { count = 0 }
    /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
    count == 1 && $0 ~ "^" key ":" { sub("^" key ":[ \t]*", ""); print; exit }
  ' "$file"
}

# frontmatter: set (or insert) a "key: value" field, in place
fm_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp=$(mktemp)
  awk -v key="$key" -v val="$value" '
    BEGIN { count = 0; done = 0 }
    /^---[[:space:]]*$/ {
      count++
      if (count == 2 && !done) { print key ": " val; done = 1 }
      print; next
    }
    count == 1 && $0 ~ "^" key ":" { print key ": " val; done = 1; next }
    { print }
  ' "$file" > "$tmp"
  mv -- "$tmp" "$file"
}

icon_type() { case "$1" in bug) printf '🐛';; feature) printf '✨';; change) printf '🔧';; chore) printf '🧹';; *) printf '▫️';; esac; }
icon_urgency() { case "$1" in essential) printf '🔴';; useful) printf '🟡';; 'nice-to-have') printf '🟢';; *) printf '⚪';; esac; }
icon_complexity() { case "$1" in low) printf '👟';; medium) printf '🥾';; high) printf '👢';; *) printf '';; esac; }
urgency_rank() { case "$1" in essential) printf 1;; useful) printf 2;; 'nice-to-have') printf 3;; *) printf 9;; esac; }
# a missing term (items created before the field existed) counts as short
icon_term() { case "$1" in long) printf '🔭';; *) printf '⚡';; esac; }
term_label() { case "$1" in long) printf 'long term';; *) printf 'short term';; esac; }

todo_dir() { printf '%s' "${1:-docs/todo}"; }

require_todo_dir() {
  local dir root
  dir=$(todo_dir "${1:-}")
  if [[ ! -d "$dir" ]]; then
    # most common cause: running from a subfolder instead of the repo root
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$root" && "$root" != "$PWD" ]]; then
      if [[ -d "$root/docs/todo" ]]; then
        die "$dir not found here — you are in a subfolder of the repo. It does exist at the root: cd '$root' and retry."
      fi
      die "$dir not found — you are in a subfolder of the repo ($root), not its root. cd there and run: $PROG init"
    fi
    die "$dir not found — run: $PROG init"
  fi
  printf '%s' "$dir"
}

# missing: no docs/todo at all. legacy: pre-existing bugs/features/planned layout
# present (not yet migrated). ready: new flat layout, safe to list/add/reindex.
cmd_detect() {
  local dir sub
  dir=$(todo_dir "${1:-}")
  if [[ ! -d "$dir" ]]; then printf 'missing\n'; return 0; fi
  # legacy item folders, or a legacy PRPs/ folder (plans now live inside the item files)
  for sub in bugs features planned PRPs; do
    if [[ -d "$dir/$sub" ]] && find "$dir/$sub" -maxdepth 2 -name '*.md' -print -quit 2>/dev/null | grep -q .; then
      printf 'legacy\n'
      return 0
    fi
  done
  printf 'ready\n'
}

# ---------- init / register ----------

cmd_init() {
  local dir
  dir=$(todo_dir "${1:-}")
  mkdir -p -- "$dir" "$dir/plan" "$dir/busy" "$dir/done" "$dir/skipped" "$dir/assets"
  cmd_register "$dir"
  cmd_reindex "$dir"
  printf 'Initialized %s\n' "$dir"
}

cmd_register() {
  local dir path name tmp
  dir=$(todo_dir "${1:-}")
  # dir is .../docs/todo — the project root is two levels up
  path=$(cd -- "$(dirname -- "$(dirname -- "$dir")")" && pwd)
  name=$(basename -- "$path")
  mkdir -p -- "$(dirname -- "$REGISTRY")"
  touch -- "$REGISTRY"
  tmp=$(mktemp)
  grep -v -F -- "$path"$'\t' "$REGISTRY" > "$tmp" || true
  mv -- "$tmp" "$REGISTRY"
  printf '%s\t%s\t%s\n' "$path" "$name" "$(today)" >> "$REGISTRY"
}

prune_registry() {
  local tmp path name seen
  [[ -f "$REGISTRY" ]] || return 0
  tmp=$(mktemp)
  while IFS=$'\t' read -r path name seen; do
    [[ -d "$path/docs/todo" ]] && printf '%s\t%s\t%s\n' "$path" "$name" "$seen"
  done < "$REGISTRY" > "$tmp"
  mv -- "$tmp" "$REGISTRY"
}

# ---------- add ----------

usage_add() {
  cat <<'USAGE'
Usage: todo.sh add --type=bug|feature|change|chore --title="..." [--urgency=essential|useful|nice-to-have]
                    [--complexity=low|medium|high] [--term=short|long] [--category=NAME] [--milestone=NAME] [dir]
USAGE
}

cmd_add() {
  local dir="" type="" title="" urgency="useful" complexity="low" term="short" category="general" milestone="" arg
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --type=*) type="${arg#*=}" ;;
      --title=*) title="${arg#*=}" ;;
      --urgency=*) urgency="${arg#*=}" ;;
      --complexity=*) complexity="${arg#*=}" ;;
      --term=*) term="${arg#*=}" ;;
      --category=*) category="${arg#*=}" ;;
      --milestone=*) milestone="${arg#*=}" ;;
      *) args+=("$arg") ;;
    esac
  done
  dir=$(require_todo_dir "${args[0]:-}")
  [[ -n "$type" ]] || { usage_add; die "--type is required"; }
  [[ -n "$title" ]] || { usage_add; die "--title is required"; }
  in_list "$type" "$VALID_TYPES" || die "--type must be one of: $VALID_TYPES"
  in_list "$urgency" "$VALID_URGENCY" || die "--urgency must be one of: $VALID_URGENCY"
  in_list "$complexity" "$VALID_COMPLEXITY" || die "--complexity must be one of: $VALID_COMPLEXITY"
  in_list "$term" "$VALID_TERM" || die "--term must be one of: $VALID_TERM"

  local created slug file
  created=$(today)
  slug=$(slugify "$title")
  file="$dir/${created}.${type}.${slug}.md"
  [[ -e "$file" ]] && file="$dir/${created}.${type}.${slug}-$(date +%H%M%S).md"

  {
    printf '%s\n' "---"
    printf 'title: %s\n' "$title"
    printf 'type: %s\n' "$type"
    printf 'urgency: %s\n' "$urgency"
    printf 'complexity: %s\n' "$complexity"
    printf 'term: %s\n' "$term"
    printf 'category: %s\n' "$category"
    printf 'status: open\n'
    printf 'created: %s\n' "$created"
    [[ -n "$milestone" ]] && printf 'milestone: %s\n' "$milestone"
    printf '%s\n' "---"
    printf '\n# %s\n\n' "$title"
    printf '## Description\n\n_TODO: fill in._\n\n'
    printf '## Analysis\n\n_TODO: fill in when investigating/designing._\n\n'
    printf '## Solution\n\n_TODO: fill in when implemented._\n\n'
    printf '## Status Log\n\n- %s: created\n' "$created"
  } > "$file"

  cmd_reindex "$dir"
  printf 'Added: %s\n%s\n\n' "$title" "$file"
  cmd_list "$dir"
}

# ---------- row collection, sorting, numbering ----------

# an item file is any .md that starts with a frontmatter block. index.md snapshots,
# legacy DONE-YYYY-MM.md monthly summaries and README files have none and are ignored.
is_item() { [[ -f "$1" ]] && head -n1 -- "$1" | grep -q '^---[[:space:]]*$'; }

# the done archive is split per month: done/YYYY-MM/. Prints every folder that can hold
# done items (the done/ root too, for anything placed there by hand).
done_dirs() {
  local dir="$1" d
  printf '%s\n' "$dir/done"
  for d in "$dir/done"/[0-9][0-9][0-9][0-9]-[0-9][0-9]; do [[ -d "$d" ]] && printf '%s\n' "$d"; done
  return 0
}

# one row per item file directly in $1:
# status F type F urgency F complexity F category F title F created F finished F path F term
# (term was added last so the path keeps field 9/10 in every consumer; empty = short)
collect_rows() {
  local scan_dir="$1" f
  for f in "$scan_dir"/*.md; do
    is_item "$f" || continue
    printf "%s${F}%s${F}%s${F}%s${F}%s${F}%s${F}%s${F}%s${F}%s${F}%s\n" \
      "$(fm_get "$f" status)" "$(fm_get "$f" type)" "$(fm_get "$f" urgency)" \
      "$(fm_get "$f" complexity)" "$(fm_get "$f" category)" "$(fm_get "$f" title)" \
      "$(fm_get "$f" created)" "$(fm_get "$f" finished)" "$f" "$(fm_get "$f" term)"
  done
}

# active pool = busy/ + plan/ + open (dir root), grouped in that order and labelled per
# group: B1.., P1.., 1.. — so a bare number always means an open item. Within a group:
# short term before long term, then by urgency, then created, then path
active_rows() {
  local dir="$1" rows
  rows=$( { collect_rows "$dir"; collect_rows "$dir/plan"; collect_rows "$dir/busy"; } )
  [[ -z "$rows" ]] && return 0
  printf '%s\n' "$rows" \
    | awk -F"$F" -v F="$F" '{
        group = ($1=="busy")?1:($1=="plan")?2:3
        rank = ($3=="essential")?1:($3=="useful")?2:($3=="nice-to-have")?3:9; if ($10=="long") rank += 10
        print group F rank F $0 }' \
    | sort -t "$F" -k1,1n -k2,2n -k9,9 -k11,11 \
    | cut -d "$F" -f3- \
    | awk -F"$F" -v F="$F" '{ p = ($1=="busy")?"B":($1=="plan")?"P":""; print p (++n[p]) F $0 }'
}

# inactive pool = done or skipped, numbered 1..N by finished date desc, then path.
# For done, $3 narrows to one month (YYYY-MM); "all" or empty means every month.
inactive_rows() {
  local dir="$1" pool="$2" month="${3:-all}" rows d
  if [[ "$pool" == "done" ]]; then
    if [[ "$month" == "all" ]]; then
      rows=$(while IFS= read -r d; do collect_rows "$d"; done < <(done_dirs "$dir"))
    else
      rows=$(collect_rows "$dir/done/$month")
    fi
  else
    rows=$(collect_rows "$dir/$pool")
  fi
  [[ -z "$rows" ]] && return 0
  printf '%s\n' "$rows" \
    | sort -t "$F" -k8,8r -k9,9 \
    | awk -F"$F" -v F="$F" '{ print (NR) F $0 }'
}

# status suffix shared by both renderers; dates shown as MM-DD to keep rows short
status_note() {
  local status="$1" path="$2" d
  case "$status" in
    plan)    d=$(fm_get "$path" plan_started); printf ' 📋 (planning since %s)' "${d:5}" ;;
    busy)    d=$(fm_get "$path" started);  printf ' (busy since %s)' "${d:5}" ;;
    done)    d=$(fm_get "$path" finished); printf ' (done %s)' "${d:5}" ;;
    skipped) printf ' (%s)' "$(fm_get "$path" skip_reason)" ;;
  esac
}

# group header printed by both renderers in "sections" mode
group_header() { case "$1" in busy) printf '🔨 busy';; plan) printf '📋 planning';; *) printf 'open';; esac; }

# compact terminal format — what `todo index|busy|urgent|done|skipped` and `pick` print:
#   "B1 🐛🔴👟⚡ Login broken · general (busy since 09-26)"
# rows on stdin: label F status F type F urgency F complexity F category F title F created F finished F path F term
# $1 = "sections": print a header before each group (busy, planning, open) and a divider
# before the first long-term open row (open is sorted short term first, so this splits
# it in two: "now" and "one day")
render() {
  local sections="${1:-}" divider_done="" group=""
  while IFS="$F" read -r pos status type urgency complexity category title created finished path term; do
    if [[ "$sections" == "sections" && "$status" != "$group" ]]; then
      printf -- '   %s\n' "$(group_header "$status")"; group="$status"
    fi
    if [[ "$sections" == "sections" && "$status" == "open" && "$term" == "long" && -z "$divider_done" ]]; then
      printf -- '   🔭 long term — one day\n'; divider_done=1
    fi
    printf -- '%2s %s%s%s%s %s · %s%s\n' \
      "$pos" "$(icon_type "$type")" "$(icon_urgency "$urgency")" "$(icon_complexity "$complexity")" \
      "$(icon_term "$term")" "$title" "$category" "$(status_note "$status" "$path")"
  done
}

# markdown format — used only for the generated index.md snapshot files, where the
# emphasis renders and the filename becomes a link
# $1 = the folder the snapshot lives in, so links are relative to it
# (the root index.md also lists busy/ items, which must link to busy/<file>)
# $2 = "sections": same long-term divider as render()
# rows are bullets with the label in front, not an ordered list: Markdown would renumber
# "P1." / "B1." items
render_md() {
  local snapdir="${1%/}" sections="${2:-}" divider_done="" group="" rel
  while IFS="$F" read -r pos status type urgency complexity category title created finished path term; do
    if [[ "$sections" == "sections" && "$status" != "$group" ]]; then
      printf -- '\n**%s**\n\n' "$(group_header "$status")"; group="$status"
    fi
    if [[ "$sections" == "sections" && "$status" == "open" && "$term" == "long" && -z "$divider_done" ]]; then
      printf -- '\n**🔭 long term — one day**\n\n'; divider_done=1
    fi
    rel="${path#"$snapdir"/}"
    printf -- '- **%s** %s%s%s **%s** _%s%s_ [%s]%s → [%s](./%s)\n' \
      "$pos" "$(icon_type "$type")" "$(icon_urgency "$urgency")" "$(icon_term "$term")" "$title" \
      "$(icon_complexity "$complexity")" "$complexity" "$category" "$(status_note "$status" "$path")" \
      "$(basename -- "$path")" "$rel"
  done
}

resolve_active() {
  local dir="$1" n line others
  n=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
  is_label "$n" || die "not an item number: $2 (use 3 for open, P2 for planning, B1 for busy)"
  line=$(active_rows "$dir" | awk -F"$F" -v n="$n" '$1==n')
  if [[ -z "$line" ]]; then
    others=$(active_rows "$dir" | cut -d "$F" -f1 | grep -E '^[PB]' | paste -sd ' ' - || true)
    die "no item $n — run '$PROG index' first to see current numbers${others:+ (planning/busy: $others)}"
  fi
  printf '%s' "$line" | cut -d "$F" -f10
}

# label_of DIR PATH — the current label (3, P2, B1) of the active item at PATH
label_of() { active_rows "$1" | awk -F"$F" -v p="$2" '$10==p { print $1 }'; }

resolve_inactive() {
  local dir="$1" pool="$2" n="$3" month="${4:-all}" line
  line=$(inactive_rows "$dir" "$pool" "$month" | awk -F"$F" -v n="$n" '$1==n')
  [[ -n "$line" ]] || die "no item #$n in $pool${month:+ ($month)} — run '$PROG $pool' first to see current numbers"
  printf '%s' "$line" | cut -d "$F" -f10
}

# ---------- moving items between folders ----------

# Images live in docs/todo/assets/ (legacy projects may also have PRPs/). Item files link
# to them relatively, so every time an item changes folder the link prefix must change with it:
#   root → assets/x.png · plan/, busy/, skipped/ → ../assets/x.png · done/YYYY-MM/ → ../../assets/x.png
rebase_asset_links() {
  local file="$1" dir="$2" rel depth prefix="" tmp
  rel="${file#"$dir"/}"
  depth=$(printf '%s' "$rel" | awk -F/ '{ print NF-1 }')
  while ((depth-- > 0)); do prefix="../$prefix"; done
  tmp=$(mktemp)
  sed -E "s#\]\(((\.\./)+|\./)?(assets|PRPs)/#](${prefix}\3/#g" "$file" > "$tmp" && mv -- "$tmp" "$file"
}

# move_file SRC DST — `git mv` when SRC is tracked, so git records a rename instead of a
# delete + add (and the item's history follows it through plan/ busy/ done/). Plain mv for
# untracked files (just added, not yet committed) and for folders outside any repo.
move_file() {
  local src="$1" dst="$2" src_dir dst_abs
  [[ -d "$dst" ]] && dst="${dst%/}/$(basename -- "$src")"
  src_dir=$(dirname -- "$src")
  if git -C "$src_dir" ls-files --error-unmatch -- "$(basename -- "$src")" >/dev/null 2>&1; then
    dst_abs="$(cd -- "$(dirname -- "$dst")" && pwd)/$(basename -- "$dst")"
    git -C "$src_dir" mv -- "$(basename -- "$src")" "$dst_abs" 2>/dev/null && return 0
  fi
  mv -- "$src" "$dst"
}

# move_item FILE DEST_DIR DIR → prints the new path
move_item() {
  local file="$1" dest="$2" dir="$3" new
  mkdir -p -- "$dest"
  new="$dest/$(basename -- "$file")"
  move_file "$file" "$new"
  rebase_asset_links "$new" "$dir"
  printf '%s\n' "$new"
}

# ---------- listings ----------

cmd_list() {
  local dir rows
  dir=$(require_todo_dir "${1:-}")
  rows=$(active_rows "$dir")
  printf 'TODO — open + plan + busy  (⚡ short term · 🔭 long term)\n'
  if [[ -z "$rows" ]]; then printf '  nothing open\n'; else printf '%s\n' "$rows" | render sections; fi
}

# short | long [dir] — the active list narrowed to one term
cmd_term_list() {
  local term="$1" dir rows
  dir=$(require_todo_dir "${2:-}")
  if [[ "$term" == "long" ]]; then
    rows=$(active_rows "$dir" | awk -F"$F" '$11=="long"')
  else
    rows=$(active_rows "$dir" | awk -F"$F" '$11!="long"')
  fi
  printf 'TODO — %s %s\n' "$(icon_term "$term")" "$(term_label "$term")"
  if [[ -z "$rows" ]]; then printf '  nothing %s open\n' "$(term_label "$term")"; else printf '%s\n' "$rows" | render; fi
}

cmd_busy() {
  local dir rows
  dir=$(require_todo_dir "${1:-}")
  rows=$(active_rows "$dir" | awk -F"$F" '$2=="busy"')
  printf 'TODO — busy (in progress)\n'
  if [[ -z "$rows" ]]; then printf '  nothing in progress\n'; else printf '%s\n' "$rows" | render; fi
}

cmd_plan_list() {
  local dir rows
  dir=$(require_todo_dir "${1:-}")
  rows=$(active_rows "$dir" | awk -F"$F" '$2=="plan"')
  printf 'TODO — planning\n'
  if [[ -z "$rows" ]]; then printf '  nothing being planned\n'; else printf '%s\n' "$rows" | render; fi
}

cmd_urgent() {
  local dir rows
  dir=$(require_todo_dir "${1:-}")
  rows=$(active_rows "$dir" | awk -F"$F" '$4=="essential"')
  printf 'TODO — urgent (essential)\n'
  if [[ -z "$rows" ]]; then printf '  nothing essential open\n'; else printf '%s\n' "$rows" | render; fi
}

# done [YYYY-MM|all] [dir] — defaults to the current month, since the archive grows to hundreds
cmd_done_list() {
  local dir="" month="" arg rows
  for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]{4}-[0-9]{2}$ || "$arg" == "all" ]]; then month="$arg"; else dir="$arg"; fi
  done
  dir=$(require_todo_dir "$dir")
  month="${month:-$(date +%Y-%m)}"
  rows=$(inactive_rows "$dir" "done" "$month")
  printf 'TODO — done (%s)\n' "$month"
  if [[ -z "$rows" ]]; then
    printf '  nothing done%s\n' "$([[ "$month" == all ]] || printf ' in %s — try: %s done all' "$month" "$PROG")"
  else
    printf '%s\n' "$rows" | render
  fi
}

cmd_skipped_list() {
  local dir rows
  dir=$(require_todo_dir "${1:-}")
  rows=$(inactive_rows "$dir" skipped)
  printf 'TODO — skipped\n'
  if [[ -z "$rows" ]]; then printf '  nothing skipped\n'; else printf '%s\n' "$rows" | render; fi
}

# ---------- interactive picker (run this directly in a terminal, not via a tool call) ----------

# render rows as "path F display-line" so the picker can show the line and still
# hand back the exact file, with no number parsing
render_with_path() {
  local rendered path
  while IFS= read -r row; do
    path=$(printf '%s' "$row" | cut -d "$F" -f10)
    rendered=$(printf '%s\n' "$row" | render)
    printf '%s%s%s\n' "$path" "$F" "$rendered"
  done
}

# pick [--show|--print] [dir]
#   default: start the item (if open) and launch an interactive `claude` session on it
#   --print: same, but `claude -p` (one-shot, prints and exits)
#   --show:  just print the item file, don't launch anything
cmd_pick() {
  local dir="" mode="claude" arg rows choice="" file="" status title prompt
  for arg in "$@"; do
    case "$arg" in
      --show) mode="show" ;;
      --print) mode="print" ;;
      *) dir="$arg" ;;
    esac
  done
  dir=$(require_todo_dir "$dir")
  rows=$(active_rows "$dir")
  [[ -n "$rows" ]] || { printf '  nothing open or busy in %s\n' "$dir"; return 0; }

  # fzf needs a real terminal; without one fall through to the plain numbered menu
  if command -v fzf >/dev/null 2>&1 && [[ -t 1 ]]; then
    choice=$(printf '%s\n' "$rows" | render_with_path | fzf \
      --delimiter="$F" --with-nth=2 --ansi --reverse --height=~80% \
      --prompt='todo> ' \
      --header='↓/↑ move · Enter = work on it in claude · Esc = cancel' \
      --preview='cat {1}' --preview-window=right:60%:wrap) || true
    [[ -n "$choice" ]] || { printf 'Cancelled.\n'; return 0; }
    file=$(printf '%s' "$choice" | cut -d "$F" -f1)
  else
    local -a menu=() paths=()
    while IFS="$F" read -r p line; do paths+=("$p"); menu+=("$line"); done < <(printf '%s\n' "$rows" | render_with_path)
    PS3='pick a todo item (number, or 0 to cancel): '
    select choice in "${menu[@]}"; do
      [[ "$REPLY" == "0" ]] && { printf 'Cancelled.\n'; return 0; }
      [[ -n "$choice" ]] && { file="${paths[REPLY-1]}"; break; }
    done
    [[ -n "$file" ]] || { printf 'Cancelled.\n'; return 0; }
  fi
  [[ -f "$file" ]] || die "could not resolve selection to a file"

  if [[ "$mode" == "show" ]]; then
    cat -- "$file"
    return 0
  fi

  status=$(fm_get "$file" status)
  local was="$status" complexity plan_step
  complexity=$(fm_get "$file" complexity)
  if [[ "$status" == "open" || "$status" == "plan" ]]; then
    file=$(start_file "$dir" "$file")
    printf 'Marked busy: %s\n' "$file"
  fi
  title=$(fm_get "$file" title)

  if [[ "$was" == "plan" ]]; then
    plan_step="This item has been planned: its Analysis section is the plan (context, blueprint, tasks in order, validation gates). Implement it from there via the /todo skill's execute flow."
  elif [[ "$complexity" == "high" || "$complexity" == "medium" ]]; then
    plan_step="This item is marked complexity: $complexity and was not planned first. Read it; if it has open questions or touches many files, propose planning it (/todo <n> plan — research, questions, then a full Analysis) before coding. Otherwise implement it directly."
  else
    plan_step="Investigate and implement it. Fill in the Analysis section as you go if it is still a placeholder."
  fi

  prompt="Work on this TODO item: \"$title\" — its detail file is $file.
Read that file first (Description / Analysis / Solution / Status Log). It is already marked busy.
$plan_step
When the work is complete and verified, use the /todo skill's \"mark as done\" flow: it moves the file to done/ and you then write up the Solution section with what was actually done."

  command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
  if [[ "$mode" == "print" ]]; then
    exec claude -p "$prompt"
  else
    exec claude "$prompt"
  fi
}

# ---------- show / state transitions (all take a position number from the last listing) ----------

cmd_show() {
  local dir file
  dir=$(require_todo_dir "${2:-}")
  file=$(resolve_active "$dir" "$1")
  cat -- "$file"
}

# move an open item file into busy/ and stamp it; prints the new path
start_file() {
  local dir="$1" file="$2" started branch
  started=$(today)
  branch=$(git -C "$(dirname -- "$dir")" branch --show-current 2>/dev/null || true)
  file=$(move_item "$file" "$dir/busy" "$dir")
  fm_set "$file" status busy
  fm_set "$file" started "$started"
  [[ -n "$branch" ]] && fm_set "$file" branch "$branch"
  printf -- '- %s: started%s\n' "$started" "${branch:+ (branch: $branch)}" >> "$file"
  cmd_reindex "$dir"
  printf '%s\n' "$file"
}

# start | execute <n> [dir] — open or planned item → busy/
cmd_start() {
  local dir file status
  dir=$(require_todo_dir "${2:-}")
  file=$(resolve_active "$dir" "$1")
  status=$(fm_get "$file" status)
  [[ "$status" == "open" || "$status" == "plan" ]] || die "item is already $status"
  file=$(start_file "$dir" "$file")
  printf 'Started (now %s): %s\n%s\n' "$(label_of "$dir" "$file")" "$(fm_get "$file" title)" "$file"
  if [[ "$status" == "open" && "$(fm_get "$file" complexity)" == "high" ]]; then
    printf 'Hint: complexity is high and it was not planned — consider: %s %s plan\n' "$PROG" "$(label_of "$dir" "$file")"
  fi
}

# plan <n> [dir] — open (or busy) item → plan/. The item file itself becomes the plan:
# the skill's "/todo <n> plan" flow researches, asks the user questions and writes a full
# Analysis into it. Then "/todo <n> execute" moves it to busy/ and implements.
cmd_plan() {
  local dir file status
  dir=$(require_todo_dir "${2:-}")
  file=$(resolve_active "$dir" "$1")
  status=$(fm_get "$file" status)
  [[ "$status" == "open" || "$status" == "busy" ]] || die "item is already $status"
  file=$(move_item "$file" "$dir/plan" "$dir")
  fm_set "$file" status plan
  fm_set "$file" plan_started "$(today)"
  printf -- '- %s: planning started%s\n' "$(today)" "$([[ "$status" == busy ]] && printf ' (back from busy)')" >> "$file"
  cmd_reindex "$dir"
  printf '📋 Planning (now %s): %s\n%s\nNext: fill in the Analysis section (context, blueprint, tasks, validation gates), then: %s %s execute\n' \
    "$(label_of "$dir" "$file")" "$(fm_get "$file" title)" "$file" "$PROG" "$(label_of "$dir" "$file")"
}

# path <n> [dir] — just the item's file path (for tooling / editing)
cmd_path() {
  local dir
  dir=$(require_todo_dir "${2:-}")
  resolve_active "$dir" "$1"
}

# brief <n> [dir] — a short preview of an item: one metadata line, then the Description
# section (max 15 lines). Made for the preview pane of a pick-from-list question.
cmd_brief() {
  local dir file status
  dir=$(require_todo_dir "${2:-}")
  file=$(resolve_active "$dir" "$1")
  status=$(fm_get "$file" status)
  printf '%s %s · %s · %s%s · %s%s · %s%s\n\n' \
    "$(icon_type "$(fm_get "$file" type)")" "$(fm_get "$file" type)" "$(fm_get "$file" urgency)" \
    "$(icon_complexity "$(fm_get "$file" complexity)")" "$(fm_get "$file" complexity)" \
    "$(icon_term "$(fm_get "$file" term)")" "$(term_label "$(fm_get "$file" term)")" \
    "$(fm_get "$file" category)" "$(status_note "$status" "$file")"
  awk '
    /^## Description/ { on = 1; next }
    /^## / && on { exit }
    on && n < 15 { print; n++ }
  ' "$file" | sed '/./,$!d'
}

cmd_done() {
  local dir file finished
  dir=$(require_todo_dir "${2:-}")
  file=$(resolve_active "$dir" "$1")
  finished=$(today)
  file=$(move_item "$file" "$dir/done/${finished:0:7}" "$dir")
  fm_set "$file" status "done"
  fm_set "$file" finished "$finished"
  printf -- '- %s: done\n' "$finished" >> "$file"
  cmd_reindex "$dir"
  printf 'Completed: %s\n%s\n' "$(fm_get "$file" title)" "$file"
}

cmd_skip() {
  local dir file reason finished
  dir=$(require_todo_dir "${3:-}")
  reason="${2:-}"
  [[ -n "$reason" ]] || die "usage: $PROG skip <n> <reason>  (reason: $VALID_SKIP_REASONS)"
  in_list "$reason" "$VALID_SKIP_REASONS" || die "reason must be one of: $VALID_SKIP_REASONS"
  file=$(resolve_active "$dir" "$1")
  finished=$(today)
  file=$(move_item "$file" "$dir/skipped" "$dir")
  fm_set "$file" status skipped
  fm_set "$file" finished "$finished"
  fm_set "$file" skip_reason "$reason"
  printf -- '- %s: skipped (%s)\n' "$finished" "$reason" >> "$file"
  cmd_reindex "$dir"
  printf 'Skipped (%s): %s\n' "$reason" "$(fm_get "$file" title)"
}

# reopen <n> [--pool=done|skipped] [--month=YYYY-MM|all] [dir]
# <n> comes from `done` (same month default: current) or `skipped`
cmd_reopen() {
  local dir="" file pool="done" month="" n="${1:-}" arg
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --pool=*) pool="${arg#*=}" ;;
      --month=*) month="${arg#*=}" ;;
      *) dir="$arg" ;;
    esac
  done
  dir=$(require_todo_dir "$dir")
  in_list "$pool" "done skipped" || die "--pool must be done or skipped"
  [[ "$pool" == "done" ]] && month="${month:-$(date +%Y-%m)}"
  file=$(resolve_inactive "$dir" "$pool" "$n" "$month")
  file=$(move_item "$file" "$dir" "$dir")
  fm_set "$file" status open
  printf -- '- %s: reopened\n' "$(today)" >> "$file"
  cmd_reindex "$dir"
  printf 'Reopened: %s\n' "$(fm_get "$file" title)"
}

# ---------- static snapshot files (for browsing in a plain editor / GitHub) ----------

cmd_reindex() {
  local dir
  dir=$(require_todo_dir "${1:-}")
  { printf '# TODO — open + plan + busy\n\n_Generated by todo.sh — do not edit by hand. Run `todo.sh index` for live numbers._\n\n'
    active_rows "$dir" | render_md "$dir" sections 2>/dev/null || printf '_none_\n'; } > "$dir/index.md"
  { printf '# TODO — busy\n\n_Generated by todo.sh — do not edit by hand._\n\n'
    { active_rows "$dir" | awk -F"$F" '$2=="busy"' | render_md "$dir/busy"; } 2>/dev/null || printf '_none_\n'; } > "$dir/busy/index.md"
  { printf '# TODO — planning\n\n_Generated by todo.sh — do not edit by hand._\n\n'
    { active_rows "$dir" | awk -F"$F" '$2=="plan"' | render_md "$dir/plan"; } 2>/dev/null || printf '_none_\n'; } > "$dir/plan/index.md"
  # done/: one index per month, plus an overview in done/index.md linking to them
  local d m count
  { printf '# TODO — done\n\n_Generated by todo.sh — do not edit by hand._\n\n'
    while IFS= read -r d; do
      m=$(basename -- "$d")
      [[ "$m" =~ ^[0-9]{4}-[0-9]{2}$ ]] || continue
      count=$(collect_rows "$d" | wc -l | tr -d ' ')
      { printf '# TODO — done in %s\n\n_Generated by todo.sh — do not edit by hand._\n\n' "$m"
        inactive_rows "$dir" "done" "$m" | render_md "$d" 2>/dev/null || printf '_none_\n'; } > "$d/index.md"
      printf -- '- [%s](./%s/index.md) — %s items\n' "$m" "$m" "$count"
    done < <(done_dirs "$dir" | sort -r)
    local legacy=""
    for d in "$dir"/done/DONE-*.md; do [[ -f "$d" ]] && legacy+="[$(basename -- "$d")](./$(basename -- "$d")) "; done
    [[ -n "$legacy" ]] && printf '\nLegacy monthly summaries: %s\n' "$legacy"
  } > "$dir/done/index.md"
  { printf '# TODO — skipped\n\n_Generated by todo.sh — do not edit by hand._\n\n'
    inactive_rows "$dir" skipped | render_md "$dir/skipped" 2>/dev/null || printf '_none_\n'; } > "$dir/skipped/index.md"
}

# ---------- global (cross-project) ----------

cmd_global() {
  local mode="${1:-summary}" path name seen dir open busy urgent
  [[ -f "$REGISTRY" ]] || die "no registry yet at $REGISTRY — run $PROG init in a project first"
  prune_registry
  while IFS=$'\t' read -r path name seen; do
    dir="$path/docs/todo"
    [[ -d "$dir" ]] || continue
    case "$mode" in
      busy)
        busy=$(cmd_busy "$dir" 2>/dev/null | grep -cE '^ *[PB]?[0-9]+ ' || true)
        ((busy > 0)) && { printf '### %s (%s)\n' "$name" "$path"; cmd_busy "$dir"; printf '\n'; }
        ;;
      urgent)
        urgent=$(cmd_urgent "$dir" 2>/dev/null | grep -cE '^ *[PB]?[0-9]+ ' || true)
        ((urgent > 0)) && { printf '### %s (%s)\n' "$name" "$path"; cmd_urgent "$dir"; printf '\n'; }
        ;;
      *)
        open=$(active_rows "$dir" | awk -F"$F" '$2=="open"' | wc -l | tr -d ' ')
        plan=$(active_rows "$dir" | awk -F"$F" '$2=="plan"' | wc -l | tr -d ' ')
        busy=$(active_rows "$dir" | awk -F"$F" '$2=="busy"' | wc -l | tr -d ' ')
        printf '%-30s open:%-3s plan:%-3s busy:%-3s  %s\n' "$name" "$open" "$plan" "$busy" "$path"
        ;;
    esac
  done < "$REGISTRY"
}

# ---------- web dashboard ----------

readonly WEB_LABEL="com.pforret.todo-web"
readonly WEB_PORT_DEFAULT="${TODO_WEB_PORT:-7474}"

web_script_dir() {
  local self="${BASH_SOURCE[0]}"
  [[ -L "$self" ]] && self="$(readlink -f -- "$self" 2>/dev/null || readlink -- "$self")"
  (cd -- "$(dirname -- "$self")" && pwd)
}
web_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$WEB_LABEL"; }
web_log() { printf '%s/.claude/state/todo-web.log' "$HOME"; }
web_is_up() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/"; }

# install|uninstall|status|restart|log: a launchd LaunchAgent that keeps the dashboard
# running from login on (macOS only). Anything else: run the server in the foreground,
# or just open the browser when a server already answers on the port.
cmd_web() {
  local script_dir port="$WEB_PORT_DEFAULT" arg args=() mode=""
  script_dir="$(web_script_dir)"
  [[ -f "$script_dir/todo-web.py" ]] || die "todo-web.py not found next to $PROG in $script_dir"
  for arg in "$@"; do
    case "$arg" in
      --port=*) port="${arg#--port=}" ;;
      install|uninstall|status|restart|log|proxy|unproxy) mode="$arg" ;;
      *) args+=("$arg") ;;
    esac
  done
  case "$mode" in
    install|uninstall|restart|proxy|unproxy)
      [[ "$(uname -s)" == "Darwin" ]] || die "todo web $mode is macOS-only (launchd / Laravel Valet); run the server with: $PROG web"
      ;;
  esac
  local python
  python="$(command -v python3 || true)"
  [[ -n "$python" ]] || die "python3 is required for the web dashboard"

  case "$mode" in
    install)
      local plist log
      plist="$(web_plist)"; log="$(web_log)"
      mkdir -p "$(dirname -- "$plist")" "$(dirname -- "$log")"
      launchctl bootout "gui/$(id -u)/$WEB_LABEL" >/dev/null 2>&1 || true
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WEB_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$python</string>
    <string>-I</string>
    <string>$script_dir/todo-web.py</string>
    <string>--no-open</string>
    <string>--port</string><string>$port</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
      launchctl bootstrap "gui/$(id -u)" "$plist" || die "launchctl bootstrap failed (see $log)"
      local i
      for i in $(seq 1 20); do web_is_up "$port" && break; sleep 0.5; done
      if web_is_up "$port"; then
        printf 'todo web: installed %s — http://127.0.0.1:%s/ is up now and from every login on\n' "$WEB_LABEL" "$port"
        printf 'todo web: log at %s; `%s web uninstall` removes it\n' "$log" "$PROG"
      else
        die "service installed but nothing answers on port $port yet — check $log"
      fi
      ;;
    uninstall)
      launchctl bootout "gui/$(id -u)/$WEB_LABEL" >/dev/null 2>&1 || true
      rm -f -- "$(web_plist)"
      printf 'todo web: %s removed\n' "$WEB_LABEL"
      ;;
    restart)
      launchctl kickstart -k "gui/$(id -u)/$WEB_LABEL" || die "not installed — run: $PROG web install"
      printf 'todo web: restarted\n'
      ;;
    status)
      if [[ -f "$(web_plist)" ]]; then
        printf 'service:  installed (%s)\n' "$(web_plist)"
        launchctl print "gui/$(id -u)/$WEB_LABEL" 2>/dev/null | grep -E '^\s+(state|pid) = ' | sed 's/^[[:space:]]*/          /'
      else
        printf 'service:  not installed (run: %s web install)\n' "$PROG"
      fi
      if web_is_up "$port"; then printf 'server:   up at http://127.0.0.1:%s/\n' "$port"; else printf 'server:   nothing answers on port %s\n' "$port"; fi
      ;;
    log)
      tail -n 50 -- "$(web_log)" 2>/dev/null || printf 'no log yet at %s\n' "$(web_log)"
      ;;
    proxy|unproxy)
      # Laravel Valet: http://<name>.test -> the dashboard (valet asks for sudo; run in a real terminal)
      command -v valet >/dev/null || die "valet not found — install Laravel Valet, or use http://127.0.0.1:$port/ directly"
      local name="${args[0]:-todolist}"
      if [[ "$mode" == "proxy" ]]; then
        valet proxy "$name" "http://127.0.0.1:$port" && printf 'todo web: http://%s.test/ now serves the dashboard (valet proxy)\n' "$name"
      else
        valet unproxy "$name" && printf 'todo web: proxy %s.test removed\n' "$name"
      fi
      ;;
    *)
      if web_is_up "$port" && [[ " ${args[*]} " != *" --json "* ]]; then
        printf 'todo web: already running at http://127.0.0.1:%s/\n' "$port"
        # the stdlib knows every platform's browser launcher (open / xdg-open / Windows)
        [[ " ${args[*]} " == *" --no-open "* ]] || "$python" -I -c 'import sys, webbrowser; webbrowser.open(sys.argv[1])' "http://127.0.0.1:$port/"
        return 0
      fi
      exec "$python" -I "$script_dir/todo-web.py" --port "$port" "${args[@]}"
      ;;
  esac
}

# ---------- migrate (legacy bugs/features/planned layout) ----------

legacy_type_from_dir() { case "$1" in bugs) printf 'bug';; features) printf 'feature';; planned) printf 'chore';; *) printf 'chore';; esac; }

# best-effort extraction from the legacy per-project conventions, which drifted
# across projects (essential/useful/nice-to-have vs 🔴🟡🟢; low/medium/high vs
# 👟🥾👢 vs one-step/multi-step/vague). Falls back to sane neutral defaults.
legacy_find_index_line() {
  local index_file="$1" legacy_sub="$2" base="$3"
  [[ -f "$index_file" ]] || return 0
  # tolerate "(bugs/x.md)" and "(./bugs/x.md)" style links alike
  grep -F -- "$legacy_sub/$base)" "$index_file" 2>/dev/null | head -n1 || true
}

legacy_urgency() {
  case "$1" in
    *essential*|*🔴*|*Critical*|*critical*|*Major*|*Blocker*) printf 'essential' ;;
    *'nice-to-have'*|*🟢*|*Minor*|*minor*|*Trivial*) printf 'nice-to-have' ;;
    *) printf 'useful' ;;
  esac
}

legacy_complexity() {
  case "$1" in
    *high*|*vague*|*👢*) printf 'high' ;;
    *low*|*one-step*|*👟*) printf 'low' ;;
    *) printf 'medium' ;;
  esac
}

legacy_category() {
  local line="$1" cat
  for cat in front-end back-end admin database api tests sysadmin security performance docs multimedia; do
    [[ "$line" == *"[$cat]"* ]] && { printf '%s' "$cat"; return; }
  done
  printf 'general'
}

legacy_title() {
  local file="$1" t
  t=$(grep -m1 '^# ' -- "$file" 2>/dev/null | sed -E 's/^# +//') || true
  case "$t" in
    Bug:*|BUG:*|bug:*|Feature:*|FEATURE:*|feature:*|Planned:*|PLANNED:*|planned:*|Change:*|CHANGE:*|change:*|Chore:*|CHORE:*|chore:*)
      t="${t#*: }" ;;
  esac
  if [[ -z "$t" ]]; then
    t=$(basename -- "$file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/-/ /g')
  fi
  printf '%s' "$t"
}

# which pool a legacy status subfolder maps to; empty = not recognised (left alone)
legacy_pool_from_subdir() {
  case "$1" in
    done|fixed|completed|closed|resolved|finished) printf 'done' ;;
    ignored|cancelled|canceled|skipped|wontfix|rejected|dropped) printf 'skipped' ;;
    *) printf '' ;;
  esac
}

# date of the last commit touching a file — the best available proxy for when a
# legacy item was finished (the old DONE-*.md summaries list titles, not files)
git_last_date() {
  local file="$1" root
  root=$(git -C "$(dirname -- "$file")" rev-parse --show-toplevel 2>/dev/null) || return 0
  git -C "$root" log -1 --format=%cs -- "$(cd -- "$(dirname -- "$file")" && pwd)/$(basename -- "$file")" 2>/dev/null || true
}

sed_inplace() { local tmp; tmp=$(mktemp); sed -E "$1" "$2" > "$tmp" && mv -- "$tmp" "$2"; }
regex_escape() { printf '%s' "$1" | sed -E 's/[][\.*^$#+?(){}|]/\\&/g'; }

# migrate [dir] [--apply]
# Converts the legacy layout (bugs/ features/ planned/, each with status subfolders like
# done/ fixed/ ignored/ cancelled/) into the flat layout. Dry run unless --apply.
#   - index.md / README.md / DONE-*.md inside legacy folders are lists, not items: ignored
#   - <type>/<status-subfolder>/x.md → done/YYYY-MM/ (month of last commit) or skipped/
#   - planned/ → chore, flagged for review (some are really features or changes)
#   - images and other non-.md files → assets/, and the links in item files are rewritten
#   - top-level DONE-YYYY-MM.md monthly summaries are kept, moved into done/
#   - files are MOVED (git sees renames); emptied legacy folders are removed
cmd_migrate() {
  local dir="" apply=0 arg legacy_sub sub pool f base type created slug newname target dest
  local index_line urgency complexity category title finished st note esc i
  local n_open=0 n_done=0 n_skipped=0 n_ignored=0 n_unknown=0
  local -a asset_old=() asset_new=() review=()
  for arg in "$@"; do
    case "$arg" in --apply) apply=1 ;; *) dir="$arg" ;; esac
  done
  dir=$(todo_dir "$dir")
  [[ -d "$dir" ]] || die "$dir not found"
  ((apply)) && mkdir -p -- "$dir/plan" "$dir/busy" "$dir/done" "$dir/skipped" "$dir/assets"

  # 1. assets first, so item links can be rewritten to their new names
  for legacy_sub in bugs features planned PRPs; do
    [[ -d "$dir/$legacy_sub" ]] || continue
    while IFS= read -r f; do
      base=$(basename -- "$f")
      target="$dir/assets/$base"
      [[ -e "$target" ]] && target="$dir/assets/${legacy_sub}-$base"
      asset_old+=("$base"); asset_new+=("$(basename -- "$target")")
      printf 'asset    %s  ->  %s\n' "$f" "$target"
      ((apply)) && move_file "$f" "$target"
    done < <(find "$dir/$legacy_sub" -maxdepth 2 -type f ! -name '*.md' ! -name '.DS_Store' 2>/dev/null | sort)
  done

  # 2. items
  for legacy_sub in bugs features planned; do
    [[ -d "$dir/$legacy_sub" ]] || continue
    while IFS= read -r f; do
      base=$(basename -- "$f")
      case "$base" in
        index.md|README.md|readme.md|DONE-*.md)
          printf 'ignore   %s  (a list, not an item — deleted on apply, it is regenerated)\n' "$f"
          n_ignored=$((n_ignored + 1)); ((apply)) && rm -- "$f"; continue ;;
      esac
      sub=$(dirname -- "$f"); sub="${sub#"$dir/$legacy_sub"}"; sub="${sub#/}"
      if [[ -z "$sub" ]]; then pool="open"; else pool=$(legacy_pool_from_subdir "$sub"); fi
      if [[ -z "$pool" ]]; then
        printf 'UNKNOWN  %s  (subfolder "%s" not recognised — left in place)\n' "$f" "$sub"
        n_unknown=$((n_unknown + 1)); continue
      fi
      type=$(legacy_type_from_dir "$legacy_sub")
      if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-(.+)\.md$ ]]; then
        created="${BASH_REMATCH[1]}"; slug="${BASH_REMATCH[2]}"
      else
        created=$(today); slug=$(slugify "${base%.md}")
      fi
      newname="${created}.${type}.${slug}.md"
      finished=""
      if [[ "$pool" != "open" ]]; then
        finished=$(git_last_date "$f"); finished="${finished:-$created}"
        [[ "$finished" < "$created" ]] && finished="$created"   # can't finish before it was created
      fi
      case "$pool" in
        open) dest="$dir" ;;
        done) dest="$dir/done/${finished:0:7}" ;;
        skipped) dest="$dir/skipped" ;;
      esac
      target="$dest/$newname"
      note=""
      [[ "$legacy_sub" == "planned" ]] && { note="   ← planned→chore: review type"; review+=("$target"); }
      printf '%-8s %s  ->  %s%s\n' "$pool" "$f" "$target" "$note"
      case "$pool" in open) n_open=$((n_open + 1));; done) n_done=$((n_done + 1));; skipped) n_skipped=$((n_skipped + 1));; esac

      if ((apply)); then
        mkdir -p -- "$dest"
        if head -n1 -- "$f" | grep -q '^---[[:space:]]*$'; then
          move_file "$f" "$target"
        else
          # tags from the old index line if it links to this file, else from the item's own
          # header (**Severity**: 🟢 Minor, **Priority**: essential, [front-end] ...)
          index_line=$(legacy_find_index_line "$dir/index.md" "$legacy_sub" "$base")
          [[ -z "$index_line" ]] && index_line=$(head -n 20 -- "$f" | grep -iE 'severity|priority|urgency|\[(front-end|back-end|admin|database|api|tests|sysadmin|security|performance|docs|multimedia)\]' || true)
          urgency=$(legacy_urgency "$index_line")
          complexity=$(legacy_complexity "$index_line")
          category=$(legacy_category "$index_line")
          title=$(legacy_title "$f")
          st="$pool"
          {
            printf '%s\n' "---"
            printf 'title: %s\n' "$title"
            printf 'type: %s\n' "$type"
            printf 'urgency: %s\n' "$urgency"
            printf 'complexity: %s\n' "$complexity"
            printf 'category: %s\n' "$category"
            printf 'status: %s\n' "$st"
            printf 'created: %s\n' "$created"
            [[ -n "$finished" ]] && printf 'finished: %s\n' "$finished"
            [[ "$st" == "skipped" ]] && printf 'skip_reason: %s\n' "$([[ "$sub" == ignored ]] && printf wontfix || printf superseded)"
            printf '%s\n' "---"
            cat -- "$f"
            printf '\n- %s: migrated from %s/%s\n' "$(today)" "$legacy_sub" "${sub:+$sub/}"
          } > "$target"
          rm -- "$f"
        fi
        # point image links at assets/ (whatever relative form they had), then fix the depth
        for ((i = 0; i < ${#asset_old[@]}; i++)); do
          esc=$(regex_escape "${asset_old[i]}")
          sed_inplace "s#\]\(([^)]*/)?${esc}\)#](assets/${asset_new[i]})#g" "$target"
        done
        rebase_asset_links "$target" "$dir"
      fi
    done < <(find "$dir/$legacy_sub" -maxdepth 2 -type f -name '*.md' 2>/dev/null | sort)
  done

  # 2b. legacy PRPs: a PRP is a plan, and plans now live inside the item file. Merge each
  #     into the item it was written for; when there is none, it becomes an item itself
  #     (PRPs/done/ → done item, PRPs/ root → planned item).
  local prp_status item n_prp_merged=0 n_prp_new=0
  local -a prp_review=() prp_check=()
  if [[ -d "$dir/PRPs" ]]; then
    while IFS= read -r f; do
      base=$(basename -- "$f")
      case "$base" in index.md|README.md|readme.md)
        printf 'ignore   %s  (a list — deleted on apply)\n' "$f"; ((apply)) && rm -- "$f"; continue ;;
      esac
      if is_item "$f"; then printf 'UNKNOWN  %s  (has frontmatter, not a PRP — left in place)\n' "$f"; n_unknown=$((n_unknown + 1)); continue; fi
      sub=$(dirname -- "$f"); sub="${sub#"$dir/PRPs"}"; sub="${sub#/}"
      if [[ -z "$sub" ]]; then prp_status="plan"; else prp_status=$(legacy_pool_from_subdir "$sub"); fi
      if [[ -z "$prp_status" ]]; then
        printf 'UNKNOWN  %s  (subfolder "%s" not recognised — left in place)\n' "$f" "$sub"; n_unknown=$((n_unknown + 1)); continue
      fi
      # match by the PRP's own slug first, then by a "Source ticket:" path it names
      local via="" related=""
      item=$(find_item_by_slug "$dir" "$(item_slug "$f")"); [[ -n "$item" ]] && via="name"
      if [[ -z "$item" ]]; then
        slug=$(prp_ref_slug "$f")
        [[ -n "$slug" ]] && item=$(find_item_by_slug "$dir" "$slug") && [[ -n "$item" ]] && via="ref"
      fi
      st=""
      if [[ -n "$item" ]]; then
        st=$(fm_get "$item" status)
        if [[ -z "$st" ]]; then   # legacy item not yet moved (dry run): status from its folder
          st=$(legacy_pool_from_subdir "$(basename -- "$(dirname -- "$item")")"); st="${st:-open}"
        fi
        # an unexecuted PRP that merely *references* a finished item is new work that grew
        # out of that item, not its plan — keep the pointer, but make it its own item
        if [[ "$prp_status" == "plan" && "$via" == "ref" && ( "$st" == "done" || "$st" == "skipped" ) ]]; then
          related="$item"; item=""
        fi
      fi
      if [[ -n "$item" ]]; then
        note=""
        [[ "$prp_status" == "plan" && "$st" == "open" ]] && note="  (item moves to plan/)"
        [[ "$prp_status" == "done" && "$st" != "done" ]] && { note="   ← PRP is done but item is $st: check"; prp_check+=("$item"); }
        printf 'prp→item %s  ->  merged into %s%s\n' "$f" "$item" "$note"
        ((apply)) && prp_merge_into "$f" "$item" "$dir" "$prp_status" >/dev/null
        n_prp_merged=$((n_prp_merged + 1))
      else
        target=$(prp_to_item "$f" "$dir" "$prp_status" feature "" "$related" dry)
        note="   ← type feature: review"
        [[ -n "$related" ]] && note="   ← its Source ticket $(basename -- "$related") is already $st, so this is new work; type feature: review"
        printf 'prp→new  %s  ->  %s%s\n' "$f" "$target" "$note"
        if ((apply)); then target=$(prp_to_item "$f" "$dir" "$prp_status" feature "" "$related"); fi
        prp_review+=("$target")
        n_prp_new=$((n_prp_new + 1))
      fi
    done < <(find "$dir/PRPs" -maxdepth 2 -type f -name '*.md' 2>/dev/null | sort)
  fi

  # 3. legacy monthly summaries stay (useful for weekly updates) but live in done/
  for f in "$dir"/DONE-*.md; do
    [[ -f "$f" ]] || continue
    printf 'keep     %s  ->  %s/done/\n' "$f" "$dir"
    ((apply)) && move_file "$f" "$dir/done/"
  done
  [[ -f "$dir/index.md" ]] && printf 'regen    %s  (old hand-written list is replaced by the generated one)\n' "$dir/index.md"

  # 4. tidy + summary
  if ((apply)); then
    for legacy_sub in bugs features planned PRPs; do
      [[ -d "$dir/$legacy_sub" ]] || continue
      find "$dir/$legacy_sub" -name '.DS_Store' -delete 2>/dev/null || true
      find "$dir/$legacy_sub" -depth -type d -empty -delete 2>/dev/null || true
      [[ -d "$dir/$legacy_sub" ]] && printf 'left     %s  (still contains unrecognised files)\n' "$dir/$legacy_sub"
    done
    cmd_reindex "$dir"
    cmd_register "$dir"
  fi
  printf '\n%s: %s open, %s done, %s skipped, %s assets; PRPs: %s merged into items, %s became items; %s list files ignored, %s unknown left in place\n' \
    "$( ((apply)) && printf 'Migrated' || printf 'Would migrate')" \
    "$n_open" "$n_done" "$n_skipped" "${#asset_old[@]}" "$n_prp_merged" "$n_prp_new" "$n_ignored" "$n_unknown"
  if ((${#review[@]} > 0)); then
    printf '\n%s planned/ items became "chore". Some may really be features or changes — check each title and fix with:\n  %s settype <file> feature|change\n' "${#review[@]}" "$PROG"
    printf '  %s\n' "${review[@]}"
  fi
  if ((${#prp_review[@]} > 0)); then
    printf '\n%s PRPs had no matching item and became items of type "feature" (complexity high). Check title and type of each:\n  %s settype <file> <type>   ·   %s set <file> complexity <c>\n' "${#prp_review[@]}" "$PROG" "$PROG"
    printf '  %s\n' "${prp_review[@]}"
    printf 'If one of them really belongs to an existing item, undo by hand: move its "### Plan" block into that item and delete the new file.\n'
  fi
  if ((${#prp_check[@]} > 0)); then
    printf '\n%s items received a finished PRP but are not done themselves — read them and mark done/skip if the work shipped:\n' "${#prp_check[@]}"
    printf '  %s\n' "${prp_check[@]}"
  fi
  ((apply)) || printf '\nDry run only. Re-run with --apply to do it.\n'
}

# ---------- legacy PRPs ----------

# title: `name: "..."`, else the first H1 (minus a "PRP:" prefix), else the filename
prp_title() {
  local f="$1" t=""
  t=$(grep -m1 -E '^name:' -- "$f" 2>/dev/null | sed -E 's/^name:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/') || true
  [[ -n "$t" ]] || t=$(grep -m1 -E '^# ' -- "$f" 2>/dev/null | sed -E 's/^# +//; s/^PRP[:-] *//') || true
  [[ -n "$t" ]] || t=$(basename -- "$f" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[.-]//; s/-/ /g')
  printf '%s' "$t"
}

# the `description: |` block of a name:/description: header, if any
prp_description() {
  awk '
    /^description:[[:space:]]*\|/ { on = 1; next }
    on && /^[^[:space:]]/ { exit }
    on { sub(/^  /, ""); print }
  ' "$1" 2>/dev/null | sed '/./,$!d' || true
}

# body without the name:/description: pseudo-frontmatter, with headings demoted one level
# (outside code fences) so the PRP nests under the item's "## Analysis"
prp_body() {
  awk '
    NR == 1 && /^name:/ { skip = 1 }
    skip {
      if (/^---[[:space:]]*$/) { skip = 0; next }
      if (/^(name|description):/ || /^[[:space:]]/ || /^$/) next
      skip = 0
    }
    /^```/ { fence = !fence }
    !fence && /^#/ { print "#" $0; next }
    { print }
  ' "$1" | sed '/./,$!d'
}

# slug = filename without date prefix and (new layout) type segment
item_slug() {
  basename -- "$1" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[.-]//; s/^(bug|feature|change|chore)\.//'
}

# slug of the item a PRP says it was written for: a `docs/todo/...md` path in a
# "Source ticket:" / "TODO ref:" line
prp_ref_slug() {
  local p
  p=$(grep -m1 -oE 'docs/todo/[^`) ]+\.md' -- "$1" 2>/dev/null || true)
  [[ -n "$p" ]] && item_slug "$p"
  return 0   # "no reference" is a normal outcome, not an error (set -e!)
}

# every item file: new layout, plus (for a dry run, before items have moved) the legacy
# bugs/ features/ planned/ folders, so PRP matching predicts the same result either way
all_item_files() {
  local dir="$1" d f
  for d in "$dir" "$dir/plan" "$dir/busy" "$dir/skipped" $(done_dirs "$dir"); do
    for f in "$d"/*.md; do is_item "$f" && printf '%s\n' "$f"; done
  done
  for d in bugs features planned; do
    [[ -d "$dir/$d" ]] || continue
    find "$dir/$d" -maxdepth 2 -type f -name '*.md' ! -name 'index.md' ! -name 'README.md' ! -name 'DONE-*.md' 2>/dev/null
  done
  return 0
}

find_item_by_slug() {
  local dir="$1" slug="$2" f
  [[ -n "$slug" ]] || return 0
  while IFS= read -r f; do
    [[ "$(item_slug "$f")" == "$slug" ]] && { printf '%s\n' "$f"; return 0; }
  done < <(all_item_files "$dir")
  return 0   # no match is a normal outcome; a loop's status is its last test (set -e!)
}

# merge a legacy PRP into an existing item's Analysis, log it, delete the PRP.
# If the PRP was not finished and the item is still open, the item moves to plan/.
# Prints the item's (possibly new) path.
prp_merge_into() {
  local prp="$1" item="$2" dir="$3" prp_status="${4:-done}" name body tmp line
  name=$(basename -- "$prp")
  body=$(prp_body "$prp")
  tmp=$(mktemp)
  if line=$(grep -n -m1 '^## Analysis' -- "$item" | cut -d: -f1) && [[ -n "$line" ]]; then
    { head -n "$line" -- "$item"
      printf '\n### Plan (migrated from PRPs/%s)\n\n%s\n' "$name" "$body"
      tail -n +"$((line + 1))" -- "$item" | grep -v '^_TODO: fill in when investigating/designing\._$' || true
    } > "$tmp"
  else
    { cat -- "$item"; printf '\n## Analysis\n\n### Plan (migrated from PRPs/%s)\n\n%s\n' "$name" "$body"; } > "$tmp"
  fi
  mv -- "$tmp" "$item"
  printf -- '- %s: merged plan from PRPs/%s\n' "$(today)" "$name" >> "$item"
  rm -- "$prp"
  if [[ "$prp_status" == "plan" && "$(fm_get "$item" status)" == "open" ]]; then
    item=$(move_item "$item" "$dir/plan" "$dir")
    fm_set "$item" status plan
    fm_set "$item" plan_started "$(today)"
  fi
  relink_assets "$item" "$dir"
  printf '%s\n' "$item"
}

# turn a legacy PRP with no matching item into an item of its own; prints the new path.
# $6 = a related item to point at (optional); $7 = "dry" to only print the target path
prp_to_item() {
  local prp="$1" dir="$2" status="$3" type="${4:-feature}" finished="${5:-}" related="${6:-}" dry="${7:-}"
  local base created slug title desc body dest target
  base=$(basename -- "$prp")
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[.-](.+)\.md$ ]]; then
    created="${BASH_REMATCH[1]}"; slug=$(slugify "${BASH_REMATCH[2]}")
  else
    created=$(git_last_date "$prp"); created="${created:-$(today)}"; slug=$(slugify "${base%.md}")
  fi
  title=$(prp_title "$prp"); desc=$(prp_description "$prp"); body=$(prp_body "$prp")
  if [[ "$status" == "done" || "$status" == "skipped" ]]; then
    [[ -n "$finished" ]] || { finished=$(git_last_date "$prp"); finished="${finished:-$created}"; }
    [[ "$finished" < "$created" ]] && finished="$created"
  fi
  case "$status" in
    plan) dest="$dir/plan" ;;
    done) dest="$dir/done/${finished:0:7}" ;;
    skipped) dest="$dir/skipped" ;;
    *) die "status must be plan, done or skipped" ;;
  esac
  target="$dest/${created}.${type}.${slug}.md"
  if [[ "$dry" == "dry" ]]; then printf '%s\n' "$target"; return 0; fi
  mkdir -p -- "$dest"
  [[ -e "$target" ]] && die "already exists: $target"
  {
    printf '%s\n' "---"
    printf 'title: %s\n' "$title"
    printf 'type: %s\n' "$type"
    printf 'urgency: useful\n'
    printf 'complexity: high\n'
    printf 'category: general\n'
    printf 'status: %s\n' "$status"
    printf 'created: %s\n' "$created"
    [[ "$status" == "plan" ]] && printf 'plan_started: %s\n' "$created"
    [[ -n "$finished" ]] && printf 'finished: %s\n' "$finished"
    [[ "$status" == "skipped" ]] && printf 'skip_reason: superseded\n'
    printf '%s\n' "---"
    printf '\n# %s\n\n## Description\n\n' "$title"
    if [[ -n "$desc" ]]; then printf '%s\n\n' "$desc"; else printf '_From a PRP that had no separate ticket — the plan below is the description._\n\n'; fi
    [[ -n "$related" ]] && printf 'Related item (this grew out of it): `%s`\n\n' "${related#"$dir"/}"
    printf '## Analysis\n\n### Plan (migrated from PRPs/%s)\n\n%s\n\n' "$base" "$body"
    printf '## Solution\n\n'
    if [[ "$status" == "done" ]]; then printf '_Implemented from the plan above (migrated PRP, no separate write-up)._\n\n'; else printf '_TODO: fill in when implemented._\n\n'; fi
    printf '## Status Log\n\n- %s: created (as PRP)\n- %s: migrated from PRPs/%s as a %s item\n' "$created" "$(today)" "$base" "$status"
  } > "$target"
  rm -- "$prp"
  relink_assets "$target" "$dir"
  printf '%s\n' "$target"
}

# import-prp <prp-file> [--into=<item-file>] [--status=plan|done|skipped] [--type=T] [--finished=D] [dir]
# One legacy PRP, with explicit choices: merge it into a given item, or make it an item.
cmd_import_prp() {
  local dir="" src="" into="" status="" type="feature" finished="" arg out
  for arg in "$@"; do
    case "$arg" in
      --into=*) into="${arg#*=}" ;;
      --status=*) status="${arg#*=}" ;;
      --type=*) type="${arg#*=}" ;;
      --finished=*) finished="${arg#*=}" ;;
      *) if [[ -z "$src" && -f "$arg" ]]; then src="$arg"; else dir="$arg"; fi ;;
    esac
  done
  dir=$(require_todo_dir "$dir")
  [[ -n "$src" ]] || die "usage: $PROG import-prp <prp-file> [--into=<item-file>] [--status=plan|done|skipped] [--type=T]"
  is_item "$src" && die "$src has frontmatter — it is an item, not a PRP"
  in_list "$type" "$VALID_TYPES" || die "--type must be one of: $VALID_TYPES"
  if [[ -n "$into" ]]; then
    is_item "$into" || die "not a todo item: $into"
    [[ -n "$status" ]] || { [[ "$src" == */done/* ]] && status="done" || status="plan"; }
    out=$(prp_merge_into "$src" "$into" "$dir" "$status")
    cmd_reindex "$dir"
    printf 'Merged into: %s\n' "$out"
  else
    [[ -n "$status" ]] || { [[ "$src" == */done/* ]] && status="done" || status="plan"; }
    out=$(prp_to_item "$src" "$dir" "$status" "$type" "$finished")
    cmd_reindex "$dir"
    printf 'New %s item: %s\n' "$status" "$out"
  fi
}

# settype <n>|<file> <type> [dir] — change an item's type (frontmatter + filename segment)
cmd_settype() {
  local dir target="${1:-}" type="${2:-}" file base newbase
  dir=$(require_todo_dir "${3:-}")
  [[ -n "$target" && -n "$type" ]] || die "usage: $PROG settype <n>|<file> <type>"
  in_list "$type" "$VALID_TYPES" || die "type must be one of: $VALID_TYPES"
  if is_label "$target"; then file=$(resolve_active "$dir" "$target"); else file="$target"; fi
  is_item "$file" || die "not a todo item: $file"
  fm_set "$file" type "$type"
  base=$(basename -- "$file")
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\.[a-z]+\.(.+)$ ]]; then
    newbase="${BASH_REMATCH[1]}.${type}.${BASH_REMATCH[2]}"
    if [[ "$newbase" != "$base" ]]; then
      move_file "$file" "$(dirname -- "$file")/$newbase"
      file="$(dirname -- "$file")/$newbase"
    fi
  fi
  printf -- '- %s: type set to %s\n' "$(today)" "$type" >> "$file"
  cmd_reindex "$dir"
  printf '%s %s: %s\n%s\n' "$(icon_type "$type")" "$type" "$(fm_get "$file" title)" "$file"
}

# set <n>|<file> <key> <value> [dir] — correct one metadata field (type goes through settype)
cmd_set() {
  local dir target="${1:-}" key="${2:-}" value="${3:-}" file
  dir=$(require_todo_dir "${4:-}")
  [[ -n "$target" && -n "$key" && -n "$value" ]] || die "usage: $PROG set <n>|<file> <urgency|complexity|term|category|milestone|title> <value>"
  case "$key" in
    urgency) in_list "$value" "$VALID_URGENCY" || die "urgency must be one of: $VALID_URGENCY" ;;
    complexity) in_list "$value" "$VALID_COMPLEXITY" || die "complexity must be one of: $VALID_COMPLEXITY" ;;
    term) in_list "$value" "$VALID_TERM" || die "term must be one of: $VALID_TERM" ;;
    category|milestone|title) ;;
    type) die "use: $PROG settype <n>|<file> <type> (it also renames the file)" ;;
    *) die "key must be one of: urgency complexity term category milestone title" ;;
  esac
  if is_label "$target"; then file=$(resolve_active "$dir" "$target"); else file="$target"; fi
  is_item "$file" || die "not a todo item: $file"
  fm_set "$file" "$key" "$value"
  printf -- '- %s: %s set to %s\n' "$(today)" "$key" "$value" >> "$file"
  cmd_reindex "$dir"
  printf '%s = %s: %s\n' "$key" "$value" "$(fm_get "$file" title)"
}

# rewrite image links in FILE to point at docs/todo/assets/ for any asset that exists there,
# whatever relative form the link had, then fix the ../ depth for the file's folder
relink_assets() {
  local file="$1" dir="$2" a esc
  for a in "$dir"/assets/*; do
    [[ -f "$a" ]] || continue
    esc=$(regex_escape "$(basename -- "$a")")
    grep -qE "\]\(([^)]*/)?${esc}\)" "$file" 2>/dev/null || continue
    sed_inplace "s#\]\(([^)]*/)?${esc}\)#](assets/$(basename -- "$a"))#g" "$file"
  done
  rebase_asset_links "$file" "$dir"
}

# import <legacy-file> --status=open|done|skipped [--type=T] [--urgency=U] [--complexity=C] [--term=short|long]
#        [--category=X] [--finished=YYYY-MM-DD] [--reason=R] [dir]
# Convert ONE legacy item (a .md without frontmatter) with explicit choices — for the
# cases `migrate` can't decide by itself: unrecognised subfolders, an item whose text
# says it's really done, a "planned" item that is really a feature, and so on.
# Missing values are inferred the same way migrate does. Assets referenced by the item
# must already be in assets/ (migrate moves them; do that first).
cmd_import() {
  local dir="" src="" status="" type="" urgency="" complexity="" term="" category="" finished="" reason="" arg
  local base created slug hint title dest target
  for arg in "$@"; do
    case "$arg" in
      --status=*) status="${arg#*=}" ;;
      --type=*) type="${arg#*=}" ;;
      --urgency=*) urgency="${arg#*=}" ;;
      --complexity=*) complexity="${arg#*=}" ;;
      --term=*) term="${arg#*=}" ;;
      --category=*) category="${arg#*=}" ;;
      --finished=*) finished="${arg#*=}" ;;
      --reason=*) reason="${arg#*=}" ;;
      *) if [[ -z "$src" && -f "$arg" ]]; then src="$arg"; else dir="$arg"; fi ;;
    esac
  done
  dir=$(require_todo_dir "$dir")
  [[ -n "$src" ]] || die "usage: $PROG import <legacy-file> --status=open|done|skipped [--type=...] ..."
  is_item "$src" && die "$src already has frontmatter — it is not a legacy file (use settype/set to correct it)"
  in_list "$status" "open done skipped" || die "--status must be open, done or skipped"
  [[ -z "$type" ]] || in_list "$type" "$VALID_TYPES" || die "--type must be one of: $VALID_TYPES"
  [[ -z "$urgency" ]] || in_list "$urgency" "$VALID_URGENCY" || die "--urgency must be one of: $VALID_URGENCY"
  [[ -z "$complexity" ]] || in_list "$complexity" "$VALID_COMPLEXITY" || die "--complexity must be one of: $VALID_COMPLEXITY"
  [[ -z "$term" ]] || in_list "$term" "$VALID_TERM" || die "--term must be one of: $VALID_TERM"
  [[ "$status" != "skipped" || -n "$reason" ]] || die "--reason is required for --status=skipped ($VALID_SKIP_REASONS)"
  [[ -z "$reason" ]] || in_list "$reason" "$VALID_SKIP_REASONS" || die "--reason must be one of: $VALID_SKIP_REASONS"

  base=$(basename -- "$src")
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[-.](.+)\.md$ ]]; then
    created="${BASH_REMATCH[1]}"; slug=$(slugify "${BASH_REMATCH[2]}")
  else
    created=$(today); slug=$(slugify "${base%.md}")
  fi
  # infer what wasn't given, from the legacy folder name and the item's header
  if [[ -z "$type" ]]; then
    case "$src" in */bugs/*) type=bug ;; */features/*) type=feature ;; */planned/*) type=chore ;; *) type=change ;; esac
  fi
  hint=$(head -n 20 -- "$src" | grep -iE 'severity|priority|urgency|\[[a-z-]+\]' || true)
  urgency="${urgency:-$(legacy_urgency "$hint")}"
  complexity="${complexity:-$(legacy_complexity "$hint")}"
  category="${category:-$(legacy_category "$hint")}"
  title=$(legacy_title "$src")
  if [[ "$status" != "open" && -z "$finished" ]]; then
    finished=$(git_last_date "$src"); finished="${finished:-$created}"
    [[ "$finished" < "$created" ]] && finished="$created"
  fi
  case "$status" in
    open) dest="$dir" ;;
    done) dest="$dir/done/${finished:0:7}" ;;
    skipped) dest="$dir/skipped" ;;
  esac
  mkdir -p -- "$dest"
  target="$dest/${created}.${type}.${slug}.md"
  [[ -e "$target" ]] && die "already exists: $target"
  {
    printf '%s\n' "---"
    printf 'title: %s\n' "$title"
    printf 'type: %s\n' "$type"
    printf 'urgency: %s\n' "$urgency"
    printf 'complexity: %s\n' "$complexity"
    [[ -n "$term" ]] && printf 'term: %s\n' "$term"
    printf 'category: %s\n' "$category"
    printf 'status: %s\n' "$status"
    printf 'created: %s\n' "$created"
    [[ -n "$finished" ]] && printf 'finished: %s\n' "$finished"
    [[ -n "$reason" ]] && printf 'skip_reason: %s\n' "$reason"
    printf '%s\n' "---"
    cat -- "$src"
    printf '\n- %s: imported from %s\n' "$(today)" "$src"
  } > "$target"
  rm -- "$src"
  relink_assets "$target" "$dir"
  cmd_reindex "$dir"
  printf '%s%s %s: %s\n%s\n' "$(icon_type "$type")" "$(icon_urgency "$urgency")" "$status" "$title" "$target"
}

# ---------- usage / help ----------

cmd_usage() {
  cat <<'USAGE'
/todo            this summary
/todo help       full command reference
/todo index (i)  busy (B1..), planning (P1..) and open (1..) items
/todo plan       items being planned
/todo busy       items in progress
/todo urgent     essential items
/todo short      short-term items (⚡ needed soon)   ·   /todo long   long-term items (🔭 one day)
/todo done       items completed this month (todo done 2026-08 · todo done all)
/todo skipped    skipped items
/todo <n>        show item <n>: 3 = open, P2 = planning, B1 = busy (from the last listing)
/todo <n> plan   move to plan/ — Claude researches, asks, writes the plan into the item
/todo <n> execute  move to busy/ and implement (also: /todo <n> start)
/todo <n> done   mark item <n> done
/todo <n> skip <reason>   mark item <n> skipped
todo pick        (terminal only) scroll open+plan+busy items, Enter = work on it in claude
/todo add ...    add a new item (--term=short|long: needed soon vs "one day")
/todo <n> set term long   move an item to the long-term list (or back: short)
/todo init       set up docs/todo in this project
USAGE
}

cmd_help() {
  cat <<'HELP'
todo.sh <command> [args] [dir]

Listings (numbers are recomputed fresh each call — always run one of these
right before acting on a number):
  index | i [dir]                     active items in three groups, each numbered on its own (also `list`):
                                       busy B1 B2.. · planning P1 P2.. · open 1 2..  — so a bare number
                                       always means an open item
  plan [dir]                          filter of the above: being planned only
  busy [dir]                          filter of the above: busy only
  urgent [dir]                        filter of the above: urgency=essential only
  short | long [dir]                  filter of the above: term=short (needed soon) or term=long ("one day")
  done [YYYY-MM|all] [dir]            done items for one month (default: this month), numbered independently
  skipped [dir]                       skipped items, numbered independently

Acting on an active item (<n> = 3 | P2 | B1, case-insensitive, from a listing just called):
  show <n> [dir]                      print an item's full detail file
  path <n> [dir]                      print just the item's file path
  brief <n> [dir]                     one metadata line + the Description (≤15 lines) — preview text
  plan <n> [dir]                      open (or busy) item → plan/. The item file becomes the plan:
                                       in Claude, /todo <n> plan researches, asks questions and writes
                                       a full Analysis (context, blueprint, tasks, validation gates)
  start | execute <n> [dir]           open or planned item → busy/ (in progress)
  done <n> [dir]                      mark an item done
  skip <n> <reason> [dir]             mark an item skipped
                                       reason: duplicate wontfix superseded cannot-reproduce out-of-scope

Acting on a numbered item from the done/skipped listing:
  reopen <n> [--pool=done|skipped] [--month=YYYY-MM|all] [dir]
                                      move an item back to open (defaults: pool done, this month)
  settype <n>|<file> <type> [dir]     change an item's type (frontmatter + filename)
  set <n>|<file> <key> <value> [dir]  correct urgency | complexity | term | category | milestone | title

Interactive (run in a real terminal, not via a tool call):
  pick [dir]                          fzf over open+plan+busy items with a preview pane; Enter marks the
                                       item busy (if open) and launches `claude` on it
  pick --print [dir]                  same, but one-shot `claude -p` (prints and exits)
  pick --show [dir]                   just print the selected item, launch nothing

Setup and maintenance:
  init [dir]                          create docs/todo structure + register project
  add --type=T --title=S [opts] [dir] create a new open item
                                       type: bug (broken, should already work) | change (small tweak to
                                       something that already works: copy/color/position/...) | feature (new)
                                             | chore (internal: refactor, upgrade, tests, CI, docs — nothing a user sees)
                                       category (free text; preferred): front-end back-end admin database api tests
                                             sysadmin security performance docs multimedia (default: general)
                                       term: short (default — needed soon: asap, this sprint) | long ("wouldn't it
                                             be nice if one day..."). Listed after every short-term item: ⚡ vs 🔭
  detect [dir]                        missing | legacy | ready — whether this project needs init/migrate
  reindex [dir]                       regenerate the snapshot index.md files
  register [dir]                      add/update this project in the global registry
  migrate [dir] [--apply]             convert a legacy bugs/features/planned layout (dry run by default):
                                       moves items to root / done/YYYY-MM / skipped, images to assets/,
                                       keeps DONE-*.md summaries in done/, flags planned/ items for retyping;
                                       PRPs/ are merged into their item's Analysis, or become items
                                       (PRPs/done → done, PRPs/ root → plan)
  import <legacy-file> --status=open|done|skipped [--type= --urgency= --complexity= --term= --category=
                                       --finished=YYYY-MM-DD --reason=] [dir]
                                      convert ONE legacy item with explicit choices — for what
                                       migrate leaves in place or gets wrong (judge by reading it)
  import-prp <prp-file> [--into=<item-file>] [--status=plan|done|skipped] [--type=T] [dir]
                                      one legacy PRP: merge it into an item's Analysis, or make it
                                       an item (migrate does this by slug match; use this to correct)

Layout: docs/todo/  <date>.<type>.<slug>.md (open)  plan/  busy/  done/YYYY-MM/  skipped/  assets/
Lifecycle: open → (plan →) busy → done | skipped
        image links in items are rewritten to the right ../ depth every time an item moves

Cross-project (uses the global registry):
  global [summary|busy|urgent]        cross-project view
  web [--port=N] [--no-open|--json]   local web dashboard over every registered project
                                       (todo-web.py, http://127.0.0.1:7474/ and /history/; just opens the
                                       browser when the server is already up; --json prints the scan)
  web install|uninstall|status|restart|log
                                      macOS launchd service: starts the dashboard at login and keeps it
                                       running, so the URL works without any terminal or IDE open
  web proxy|unproxy [name]            Laravel Valet proxy so http://<name>.test (default todolist) serves
                                       the dashboard — valet needs sudo, so run this in a real terminal
HELP
}

# ---------- dispatch ----------

main() {
  local cmd="${1:-usage}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    usage) cmd_usage ;;
    help|-h|--help) cmd_help ;;
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    list) cmd_list "$@" ;;
    index|i)
      if [[ $# -gt 0 ]] && is_label "$1"; then cmd_show "$@"; else cmd_list "$@"; fi
      ;;
    show) cmd_show "$@" ;;
    path) cmd_path "$@" ;;
    brief) cmd_brief "$@" ;;
    start|execute) cmd_start "$@" ;;
    plan)
      if [[ $# -gt 0 ]] && is_label "$1"; then cmd_plan "$@"; else cmd_plan_list "$@"; fi
      ;;
    done)
      if [[ $# -gt 0 ]] && is_label "$1"; then cmd_done "$@"; else cmd_done_list "$@"; fi
      ;;
    skip) cmd_skip "$@" ;;
    skipped) cmd_skipped_list "$@" ;;
    reopen) cmd_reopen "$@" ;;
    settype) cmd_settype "$@" ;;
    set) cmd_set "$@" ;;
    import) cmd_import "$@" ;;
    import-prp) cmd_import_prp "$@" ;;
    pick) cmd_pick "$@" ;;
    busy) cmd_busy "$@" ;;
    urgent) cmd_urgent "$@" ;;
    short|long) cmd_term_list "$cmd" "$@" ;;
    reindex) cmd_reindex "$@" ;;
    register) cmd_register "$@" ;;
    global) cmd_global "$@" ;;
    web) cmd_web "$@" ;;
    migrate) cmd_migrate "$@" ;;
    detect) cmd_detect "$@" ;;
    *)
      if is_label "$cmd"; then cmd_show "$cmd" "$@"; else cmd_help; die "unknown command: $cmd"; fi
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
