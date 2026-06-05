type SerialStats = {
  writeCount: number
  errorCount: number
  lastWriteMs: number
  averageWriteMs: number
  maxWriteMs: number
  lastError: string
}

type MouseStats = {
  eventCount: number
  moveEventCount: number
  reportCount: number
  eventsPerSecond: number
  movesPerSecond: number
  reportsPerSecond: number
  lastEventAt: number
  lastReportAt: number
}

const serialStats: SerialStats = {
  writeCount: 0,
  errorCount: 0,
  lastWriteMs: 0,
  averageWriteMs: 0,
  maxWriteMs: 0,
  lastError: ''
}

const mouseStats: MouseStats = {
  eventCount: 0,
  moveEventCount: 0,
  reportCount: 0,
  eventsPerSecond: 0,
  movesPerSecond: 0,
  reportsPerSecond: 0,
  lastEventAt: 0,
  lastReportAt: 0
}

const recentMouseEvents: number[] = []
const recentMouseMoves: number[] = []
const recentMouseReports: number[] = []

function now(): number {
  return typeof performance !== 'undefined' ? performance.now() : Date.now()
}

function trimRecent(values: number[], currentTime: number): void {
  const cutoff = currentTime - 1000
  while (values.length > 0 && values[0] < cutoff) {
    values.shift()
  }
}

function updateRates(currentTime: number): void {
  trimRecent(recentMouseEvents, currentTime)
  trimRecent(recentMouseMoves, currentTime)
  trimRecent(recentMouseReports, currentTime)

  mouseStats.eventsPerSecond = recentMouseEvents.length
  mouseStats.movesPerSecond = recentMouseMoves.length
  mouseStats.reportsPerSecond = recentMouseReports.length
}

export function recordSerialWrite(durationMs: number): void {
  serialStats.writeCount += 1
  serialStats.lastWriteMs = durationMs
  serialStats.maxWriteMs = Math.max(serialStats.maxWriteMs, durationMs)
  serialStats.averageWriteMs =
    (serialStats.averageWriteMs * (serialStats.writeCount - 1) + durationMs) /
    serialStats.writeCount
}

export function recordSerialError(error: unknown): void {
  serialStats.errorCount += 1
  serialStats.lastError = error instanceof Error ? error.message : String(error)
}

export function recordMouseEvent(kind: 'move' | 'button' | 'wheel' | 'touch'): void {
  const currentTime = now()
  mouseStats.eventCount += 1
  mouseStats.lastEventAt = Date.now()
  recentMouseEvents.push(currentTime)

  if (kind === 'move' || kind === 'touch') {
    mouseStats.moveEventCount += 1
    recentMouseMoves.push(currentTime)
  }

  updateRates(currentTime)
}

export function recordMouseReport(): void {
  const currentTime = now()
  mouseStats.reportCount += 1
  mouseStats.lastReportAt = Date.now()
  recentMouseReports.push(currentTime)
  updateRates(currentTime)
}

export function getRuntimeDiagnostics(): {
  serial: SerialStats
  mouse: MouseStats
} {
  updateRates(now())

  return {
    serial: {
      ...serialStats,
      lastWriteMs: Number(serialStats.lastWriteMs.toFixed(2)),
      averageWriteMs: Number(serialStats.averageWriteMs.toFixed(2)),
      maxWriteMs: Number(serialStats.maxWriteMs.toFixed(2))
    },
    mouse: { ...mouseStats }
  }
}
