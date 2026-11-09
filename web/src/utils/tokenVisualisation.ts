/** Timeline tick helpers (the token-marker helpers went with the old Graph tab overlay, T-1520). */

/**
 * Determine visual significance of an event for timeline tick height
 */
export function getEventSignificance(eventType: string): 'high' | 'medium' | 'low' {
  const highSignificance = [
    'INSTANCE_STARTED',
    'INSTANCE_COMPLETED',
    'INSTANCE_CANCELLED',
    'INSTANCE_ERROR',
    'TASK_CREATED',
    'TASK_COMPLETED',
    'GATEWAY_EVALUATED',
    'TIMER_TRIGGERED',
  ]

  const mediumSignificance = [
    'TOKEN_MOVED',
    'TOKEN_CREATED',
    'TOKEN_COMPLETED',
    'VARIABLE_UPDATED',
  ]

  if (highSignificance.includes(eventType)) {
    return 'high'
  } else if (mediumSignificance.includes(eventType)) {
    return 'medium'
  }
  return 'low'
}

/**
 * Compute tick positions for timeline visualization
 */
export function computeTickPositions(
  totalEvents: number,
  trackWidth: number
): Array<{ position: number; significance: 'high' | 'medium' | 'low' }> {
  if (totalEvents <= 0) return []

  const ticks: Array<{ position: number; significance: 'high' | 'medium' | 'low' }> = []

  // Always include first and last
  ticks.push({ position: 0, significance: 'high' })
  if (totalEvents > 1) {
    ticks.push({ position: trackWidth, significance: 'high' })
  }

  return ticks
}
