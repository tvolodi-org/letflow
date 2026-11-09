/** diagramConfig — T-1520. Starting values of the read-only process diagram, kept in one place
 *  (docs/design/process-designer.md, "Large definitions"). */
import type { NodeState } from '@/utils/canvas/instancePath'
import type { StatusGlyph, StatusTone } from '@/components/ui/StatusPill'

export const diagramConfig = {
  /** Above this many nodes: no minimap, no edge animation, only visible elements are rendered. */
  bigGraphNodes: 150,
  /** Above this many nodes: the step list only, with a banner. */
  hugeGraphNodes: 400,
  /** Below this container width the step list replaces the canvas. */
  narrowWidth: 640,
  /** From this container width a chain is laid out left to right and the details panel sits beside the canvas. */
  wideWidth: 900,
  /** Canvas height follows the laid-out drawing: its height plus this padding, kept between the two limits (px). The
   *  cap keeps the whole canvas in a 900 px window: the wheel zooms the canvas, so a taller one would trap page scrolling. */
  canvasPadding: 48,
  canvasMinHeight: 360,
  canvasMaxHeight: 700,
  /** Extra canvas height kept under the drawing for the minimap (bottom right; --space-24 tall plus its margins). */
  minimapReserve: 128,
  minZoom: 0.2,
  /** The first view never shrinks the drawing below this scale, so canvas text stays readable (13 px labels at
   *  about 12 px); a larger drawing is panned. The "fit view" control can still show it whole. */
  readableZoom: 0.9,
  maxZoom: 1.5,
  /** Form fields listed in the details panel before "+n more". */
  formFieldCap: 12,
  /** Edge label length before it is cut (the full text is in the title and the step list). */
  edgeLabelMax: 28,
} as const

/** The attribute keys the diagram knows, per node type: the note's inventory table must name each one (test D2). */
export const FORMAT_KEYS: Readonly<Record<string, readonly string[]>> = {
  HUMAN_TASK: ['role', 'assignee_type', 'assignee_ref', 'form_schema', 'validation_script_key', 'distinct_from', 'module_writes'],
  SERVICE_TASK: ['endpoint', 'service_id', 'script_key', 'script_version', 'timeout_ms', 'module_writes'],
  TIMER: ['duration_iso8601'],
  SUB_PROCESS: ['definition_name', 'interface'],
  ANY: ['position'],
}

export const STATE_PILL: Record<NodeState, { tone: StatusTone; glyph: StatusGlyph }> = {
  done: { tone: 'success', glyph: 'dot' },
  active: { tone: 'current', glyph: 'ring' },
  error: { tone: 'danger', glyph: 'triangle' },
  skipped: { tone: 'neutral', glyph: 'dash' },
  pending: { tone: 'neutral', glyph: 'ring' },
  unclear: { tone: 'warning', glyph: 'half' },
}

export const NODE_TYPES = [
  'START',
  'END',
  'HUMAN_TASK',
  'SERVICE_TASK',
  'EXCLUSIVE_GATEWAY',
  'PARALLEL_GATEWAY',
  'TIMER',
  'SUB_PROCESS',
] as const
