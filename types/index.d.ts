export type TodoStatus = 'open' | 'plan' | 'busy' | 'done' | 'skipped'
export type Filter = 'all' | TodoStatus

export type TodoItem = {
  project: string
  path: string
  file: string
  title: string
  type: string
  urgency: string
  complexity: string
  category: string
  status: TodoStatus
  /** the date that matters for the status: created / plan_started / started / finished */
  date: string
}

export type Scan = {
  items: TodoItem[]
  projects: number
  scannedAt: number
  error?: string
}

declare module 'claude-code' {
  interface PluginState {
    'todo-md': {
      scan: Scan
      filter: Filter
      project: string
    }
  }
}
