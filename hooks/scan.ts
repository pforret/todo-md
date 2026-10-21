import type { TodoItem, TodoStatus } from '../types'

export const STATUSES: readonly TodoStatus[] = ['open', 'plan', 'busy', 'done', 'skipped']

const STATUS_RANK: Record<TodoStatus, number> = { busy: 0, plan: 1, open: 2, done: 3, skipped: 4 }
const URGENCY_RANK: Record<string, number> = { essential: 0, useful: 1, 'nice-to-have': 2 }

export type Frontmatter = Record<string, string>

/** The YAML "key: value" block between the first two --- lines. */
export function parseFrontmatter(text: string): Frontmatter {
  const out: Frontmatter = {}
  const lines = text.split(/\r?\n/)
  let fences = 0
  for (const line of lines) {
    if (/^---\s*$/.test(line)) {
      fences += 1
      if (fences === 2) break
      continue
    }
    if (fences !== 1) continue
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line)
    if (m) out[m[1]] = m[2].trim().replace(/^["']|["']$/g, '')
  }
  return out
}

/** The date column shown for a status. */
export function dateFor(fm: Frontmatter, status: TodoStatus): string {
  switch (status) {
    case 'plan': return fm.plan_started ?? fm.created ?? ''
    case 'busy': return fm.started ?? fm.created ?? ''
    case 'done': return fm.finished ?? fm.created ?? ''
    default: return fm.created ?? ''
  }
}

export function toItem(project: string, path: string, file: string, status: TodoStatus, text: string): TodoItem {
  const fm = parseFrontmatter(text)
  const name = file.replace(/^.*\//, '')
  const fromName = /^\d{4}-\d{2}-\d{2}\.([a-z]+)\.(.+)\.md$/.exec(name)
  return {
    project,
    path,
    file,
    title: fm.title ?? (fromName ? fromName[2].replace(/-/g, ' ') : name),
    type: fm.type ?? fromName?.[1] ?? '',
    urgency: fm.urgency ?? '',
    complexity: fm.complexity ?? '',
    category: fm.category ?? '',
    status: (STATUSES.includes(fm.status as TodoStatus) ? fm.status : status) as TodoStatus,
    date: dateFor(fm, status),
  }
}

/** busy first, then plan, open, done, skipped; essential before useful; newest first within. */
export function sortItems(items: TodoItem[]): TodoItem[] {
  return [...items].sort((a, b) =>
    STATUS_RANK[a.status] - STATUS_RANK[b.status]
    || (URGENCY_RANK[a.urgency] ?? 9) - (URGENCY_RANK[b.urgency] ?? 9)
    || b.date.localeCompare(a.date)
    || a.project.localeCompare(b.project)
    || a.title.localeCompare(b.title),
  )
}

export function parseRegistry(text: string): { path: string; name: string }[] {
  return text
    .split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .map(line => {
      const [path, name] = line.split('\t')
      return { path, name: name || path.replace(/^.*\//, '') }
    })
}

export const isItemFile = (name: string) => name.endsWith('.md') && name !== 'index.md' && !/^DONE-/.test(name)
export const isDoneMonth = (name: string) => /^\d{4}-\d{2}$/.test(name)
