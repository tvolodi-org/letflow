/**
 * Q-1075 / GH #2432: client-reported time spent per question.
 *
 * Time on a question is the wall-clock time it has been the current question, summed
 * across revisits within this page mount, and reported to the server as a whole-second
 * running total on every save. The stored value is the server's job to bound (it takes
 * the max with what is stored and clamps to the session's elapsed time).
 *
 * Known limit (GH #2432): this is client-reported. A per-question "shown" event on the
 * server is out of scope, so the value is bounded, not server-measured.
 *
 * Pure functions over a mutable clock object, so the accounting can be unit-tested
 * without rendering the exam page.
 */

export interface DwellClock {
  /** The question currently on screen, or undefined when none is. */
  current: string | undefined
  /** Epoch ms at which `current` became the current question (or the last flush). */
  since: number
  /** Milliseconds measured on each question during this page mount, across revisits. */
  measuredMs: Record<string, number>
  /** The stored seconds each question had when it was first saved in this mount. */
  baseSeconds: Record<string, number>
}

export function createDwellClock(now: number): DwellClock {
  return { current: undefined, since: now, measuredMs: {}, baseSeconds: {} }
}

/** Charge the time since the last flush to the current question. Never goes backwards. */
function flush(clock: DwellClock, now: number): void {
  const elapsed = Math.max(now - clock.since, 0)
  if (clock.current !== undefined) {
    clock.measuredMs[clock.current] = (clock.measuredMs[clock.current] ?? 0) + elapsed
  }
  clock.since = now
}

/** Called when the question on screen changes: charges the previous one, starts the new one. */
export function switchQuestion(clock: DwellClock, questionId: string | undefined, now: number): void {
  flush(clock, now)
  clock.current = questionId
}

/**
 * The whole-second running total to report for `questionId` on a save: the stored seconds
 * the question had when this mount first saved it, plus the time measured since, floored.
 */
export function recordSaveTotal(
  clock: DwellClock,
  questionId: string,
  storedSeconds: number,
  now: number,
): number {
  flush(clock, now)
  clock.baseSeconds[questionId] ??= storedSeconds
  const measured = clock.measuredMs[questionId] ?? 0
  return clock.baseSeconds[questionId] + Math.floor(measured / 1000)
}
