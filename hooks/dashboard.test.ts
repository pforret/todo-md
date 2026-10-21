import { describe, expect, mock, test } from 'claude-code/testing'

import type { TodoItem } from '../types'
import { applyFilter, countBy } from './register'
import { parseFrontmatter, parseRegistry, sortItems, toItem } from './scan'

const SAMPLE = `---
title: Replace Conductor import with the calendar API
type: chore
urgency: useful
complexity: medium
category: back-end
status: open
created: 2026-10-06
---

# Replace Conductor import
`

describe('scan parsers', () => {
  test('frontmatter is read from the first --- block only', async () => {
    const fm = parseFrontmatter(SAMPLE + '\n---\nstatus: done\n---\n')
    expect(fm.title).toBe('Replace Conductor import with the calendar API')
    expect(fm.status).toBe('open')
    expect(fm.created).toBe('2026-10-06')
  })

  test('toItem takes status from the folder and date from the status', async () => {
    const busyText = SAMPLE.replace('status: open', 'status: busy') + 'started: 2026-10-07\n'
    const item = toItem('spottix', '/p', '/p/docs/todo/busy/2026-10-06.chore.replace.md', 'busy', SAMPLE.replace('status: open\n', 'status: busy\nstarted: 2026-10-07\n'))
    expect(item.status).toBe('busy')
    expect(item.date).toBe('2026-10-07')
    expect(item.type).toBe('chore')
    expect(busyText.length).toBeGreaterThan(0)
  })

  test('toItem falls back to the file name when the frontmatter is missing', async () => {
    const item = toItem('p', '/p', '/p/docs/todo/2026-10-01.bug.login-fails.md', 'open', 'no frontmatter here')
    expect(item.title).toBe('login fails')
    expect(item.type).toBe('bug')
    expect(item.status).toBe('open')
  })

  test('registry rows are path<TAB>name<TAB>seen', async () => {
    const rows = parseRegistry('/a/b/proj\tproj\t2026-09-26\n/c/d/other\tother\t2026-10-05\n\n')
    expect(rows.length).toBe(2)
    expect(rows[1].name).toBe('other')
    expect(rows[1].path).toBe('/c/d/other')
  })
})

const item = (status: TodoItem['status'], project: string, urgency = 'useful', date = '2026-10-01'): TodoItem => ({
  project, path: '/' + project, file: `/${project}/${status}/${date}.md`, title: `${status} in ${project}`,
  type: 'chore', urgency, complexity: 'low', category: 'general', status, date,
})

describe('dashboard filters', () => {
  const items = sortItems([
    item('done', 'a'), item('open', 'b'), item('busy', 'a'), item('plan', 'b'), item('skipped', 'a'),
    item('open', 'a', 'essential'), item('busy', 'b', 'useful', '2026-10-05'),
  ])

  test('busy items sort first, then plan, open, done, skipped', async () => {
    expect(items.map(i => i.status).join(',')).toBe('busy,busy,plan,open,open,done,skipped')
    expect(items[0].project).toBe('b')
  })

  test('status filter keeps only that status', async () => {
    expect(applyFilter(items, 'busy', '').length).toBe(2)
    expect(applyFilter(items, 'done', '').length).toBe(1)
    expect(applyFilter(items, 'all', '').length).toBe(7)
  })

  test('project filter combines with status filter', async () => {
    expect(applyFilter(items, 'all', 'a').length).toBe(4)
    expect(applyFilter(items, 'open', 'a').length).toBe(1)
    expect(applyFilter(items, 'plan', 'a').length).toBe(0)
  })

  test('countBy totals every status', async () => {
    const counts = countBy(items)
    expect(counts.busy).toBe(2)
    expect(counts.open).toBe(2)
    expect(counts.skipped).toBe(1)
  })
})

describe('pane', () => {
  for (const surface of ['terminal', 'desktop'] as const) {
    test(`draws the filter buttons and empty state on ${surface}`, async ($, on) => {
      mock.clock(on)
      mock.env(on, { HOME: '/nonexistent' })
      // the engine's own bottom for ui.render: nothing drawn beneath the plugin
      on('ui.render', () => ({ type: 'Box', props: {}, children: [] }) as never)
      const drawn = await $.ui.mount({
        plugin: 'todo-md',
        surface,
        component: 'Pane',
        requestId: 'todo-dashboard',
        props: { title: 'TODO dashboard', isFocused: false, bodyColumns: 120, placement: 'dock' } as never,
      })
      expect(await drawn.find({ key: 'filter-busy' })).toBeDefined()
      expect(await drawn.find({ key: 'filter-done' })).toBeDefined()
      await drawn.press({ key: 'filter-busy' })
      const busy = await drawn.find({ key: 'filter-busy' })
      expect(busy?.props.variant).toBe('primary')
      const all = await drawn.find({ key: 'filter-all' })
      expect(all?.props.variant).toBe('secondary')
      expect((await drawn.find({ type: 'Text' }))?.text).toBe('Scanning registered projects…')
    })
  }
})
