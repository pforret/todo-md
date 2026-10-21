import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Filter, Scan, TodoItem, TodoStatus } from '../types'
import { STATUSES, isDoneMonth, isItemFile, parseRegistry, sortItems, toItem } from './scan'

const PANE = 'todo-dashboard'
const TITLE = 'TODO dashboard'
const REFRESH_MS = 60_000

const EMPTY: Scan = { items: [], projects: 0, scannedAt: 0 }
const scan = atom({ plugin: 'todo-dashboard', key: 'scan' } as const, EMPTY)
const filter = atom({ plugin: 'todo-dashboard', key: 'filter' } as const, 'all' as Filter)
const project = atom({ plugin: 'todo-dashboard', key: 'project' } as const, '')

const FILTERS: readonly { value: Filter; label: string; hotkey: string }[] = [
  { value: 'all', label: 'all', hotkey: 'a' },
  { value: 'busy', label: 'busy', hotkey: 'b' },
  { value: 'plan', label: 'plan', hotkey: 'p' },
  { value: 'open', label: 'open', hotkey: 'o' },
  { value: 'done', label: 'done', hotkey: 'd' },
  { value: 'skipped', label: 'skipped', hotkey: 's' },
]

const STATUS_COLOR: Record<TodoStatus, string> = {
  busy: 'warning',
  plan: 'ide',
  open: 'text',
  done: 'success',
  skipped: 'inactive',
}
const TYPE_ICON: Record<string, string> = { bug: '🐛', feature: '✨', change: '🔧', chore: '🧹' }
const URGENCY_ICON: Record<string, string> = { essential: '🔴', useful: '🟡', 'nice-to-have': '🟢' }

export function applyFilter(items: TodoItem[], status: Filter, projectName: string): TodoItem[] {
  return items.filter(
    item => (status === 'all' || item.status === status) && (projectName === '' || item.project === projectName),
  )
}

export function countBy(items: TodoItem[]): Record<TodoStatus, number> {
  const counts = { open: 0, plan: 0, busy: 0, done: 0, skipped: 0 }
  for (const item of items) counts[item.status] += 1
  return counts
}

async function itemsIn($: EngineInterface, project: string, root: string, dir: string, status: TodoStatus): Promise<TodoItem[]> {
  const entries = await $.fs.list(dir).catch(() => [])
  const files = entries.filter(e => e.kind === 'file' && isItemFile(e.name))
  return Promise.all(
    files.map(async e => {
      const file = `${dir}/${e.name}`
      const text = await $.fs.read(file).catch(() => '')
      return toItem(project, root, file, status, typeof text === 'string' ? text : '')
    }),
  )
}

/** One project's docs/todo tree: flat = open, plan/, busy/, done/YYYY-MM/, skipped/. */
async function scanProject($: EngineInterface, project: string, root: string): Promise<TodoItem[]> {
  const todo = `${root}/docs/todo`
  if (!(await $.fs.exists(todo).catch(() => false))) return []
  const doneMonths = (await $.fs.list(`${todo}/done`).catch(() => []))
    .filter(e => e.kind === 'dir' && isDoneMonth(e.name))
    .map(e => `${todo}/done/${e.name}`)
  const groups = await Promise.all([
    itemsIn($, project, root, todo, 'open'),
    itemsIn($, project, root, `${todo}/plan`, 'plan'),
    itemsIn($, project, root, `${todo}/busy`, 'busy'),
    itemsIn($, project, root, `${todo}/skipped`, 'skipped'),
    ...doneMonths.map(m => itemsIn($, project, root, m, 'done')),
  ])
  return groups.flat()
}

/** Every project in ~/.claude/state/todo-projects.tsv (or $TODO_REGISTRY), as todo.sh keeps it. */
async function scanAll($: EngineInterface): Promise<Scan> {
  const scannedAt = await $.clock.now()
  const home = (await $.env.get('HOME')) ?? ''
  const registry = (await $.env.get('TODO_REGISTRY')) ?? `${home}/.claude/state/todo-projects.tsv`
  const text = await $.fs.read(registry).catch(() => undefined)
  if (typeof text !== 'string') {
    return { items: [], projects: 0, scannedAt, error: `no registry at ${registry} — run /todo init in a project first` }
  }
  const projects = parseRegistry(text)
  const perProject = await Promise.all(projects.map(p => scanProject($, p.name, p.path)))
  return { items: sortItems(perProject.flat()), projects: projects.length, scannedAt }
}

async function refresh($: EngineInterface): Promise<Scan> {
  const result = await scanAll($)
  await update($, scan, () => result)
  return result
}

export const register: Register = on => {

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'todo-dashboard',
      description: 'Open the cross-project TODO dashboard pane (filter: busy, plan, open, done, skipped)',
      argumentHint: '[busy|plan|open|done|skipped|all] [refresh]',
    })
    void refresh($)
    $.clock.every(REFRESH_MS, () => void refresh($))
    void $.ui.open({ id: PANE, title: TITLE })

    return next(e)
  })

  on('command.run', { command: 'todo-dashboard' }, async ($, e) => {
    const words = (e.args ?? '').trim().split(/\s+/).filter(Boolean)
    const wanted = words.find((w): w is Filter => w === 'all' || STATUSES.includes(w as TodoStatus))
    if (wanted) await update($, filter, () => wanted)
    const result = await refresh($)
    const opened = await $.ui.open({ id: PANE, title: TITLE, focus: true })
    const counts = countBy(result.items)
    const summary = `${result.items.length} items in ${result.projects} projects — busy ${counts.busy}, plan ${counts.plan}, open ${counts.open}, done ${counts.done}, skipped ${counts.skipped}`
    return { text: opened.isPlaced ? `TODO dashboard: ${summary}` : `TODO dashboard (widen the terminal to see the pane): ${summary}` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const data = await read($, scan)
    const status = await read($, filter)
    const projectName = await read($, project)
    const columns = e.props.bodyColumns ?? e.viewport?.columns ?? 100
    const rows = Math.max(3, (e.viewport?.rows ?? 24) - 6)

    const counts = countBy(data.items)
    const visible = applyFilter(data.items, status, projectName)
    const projects = [...new Set(data.items.map(i => i.project))].sort()
    const shown = visible.slice(0, rows)
    const hidden = visible.length - shown.length

    const projectWidth = Math.min(22, Math.max(8, ...projects.map(p => p.length)))
    const titleWidth = Math.max(10, columns - projectWidth - 24)
    const fit = (text: string, width: number) => (text.length > width ? text.slice(0, width - 1) + '…' : text.padEnd(width))

    return (
      <Box flexDirection="column">
        <Box gap={1} flexWrap="wrap">
          {FILTERS.map(f => (
            <Button
              key={`filter-${f.value}`}
              hotkey={f.hotkey}
              variant={f.value === status ? 'primary' : 'secondary'}
              dimColor={f.value !== status}
              onPress={() => update($, filter, () => f.value)}
            >
              {f.value === 'all' ? `all ${data.items.length}` : `${f.label} ${counts[f.value]}`}
            </Button>
          ))}
          <Button key="refresh" hotkey="r" plain dimColor onPress={() => void refresh($)}>
            r: refresh
          </Button>
        </Box>
        {projects.length > 1 && (
          <Box gap={1} flexWrap="wrap">
            <Button key="project-all" plain dimColor={projectName !== ''} onPress={() => update($, project, () => '')}>
              every project
            </Button>
            {projects.map(p => (
              <Button key={`project-${p}`} plain dimColor={p !== projectName} onPress={() => update($, project, () => p)}>
                {p}
              </Button>
            ))}
          </Box>
        )}
        <Box marginTop={1} flexDirection="column">
          {data.error && <Text color="error">{data.error}</Text>}
          {!data.error && data.scannedAt === 0 && <Text dimColor>Scanning registered projects…</Text>}
          {!data.error && data.scannedAt > 0 && visible.length === 0 && (
            <Text dimColor>No {status === 'all' ? '' : status + ' '}items{projectName ? ` in ${projectName}` : ''}.</Text>
          )}
          {shown.map(item => (
            <Box key={item.file} gap={1}>
              <Text color={STATUS_COLOR[item.status]} bold={item.status === 'busy'}>{fit(item.status, 7)}</Text>
              <Text dimColor>{fit(item.project, projectWidth)}</Text>
              <Text>{TYPE_ICON[item.type] ?? '▫️'}{URGENCY_ICON[item.urgency] ?? '⚪'}</Text>
              <Text wrap="truncate-end">{fit(item.title, titleWidth)}</Text>
              <Text dimColor>{item.date.slice(5)}</Text>
            </Box>
          ))}
          {hidden > 0 && <Text dimColor>… {hidden} more (narrow the filter)</Text>}
        </Box>
        <Box marginTop={1}>
          <Text dimColor>
            {data.projects} projects · {data.items.length} items · scanned {data.scannedAt ? new Date(data.scannedAt).toLocaleTimeString() : 'never'} · refreshes every {REFRESH_MS / 1000}s
          </Text>
        </Box>
      </Box>
    )
  })
}
