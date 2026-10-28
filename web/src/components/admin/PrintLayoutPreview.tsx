/** PrintLayoutPreview — REQ-614: on-screen preview drawn from the layout alone.
 *
 *  Pure: no hooks, no request, no stored data. Fields and table cells show a
 *  placeholder `[entity_type.field_name]`. Only React text nodes are emitted.
 */
import React from 'react'

type Obj = Record<string, unknown>

function isObj(v: unknown): v is Obj {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null
}

function placeholder(entityType: unknown, fieldName: unknown): string {
  return `[${str(entityType) ?? '?'}.${str(fieldName) ?? '?'}]`
}

function spacerHeight(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? Math.min(200, Math.max(0, v)) : 0
}

const cell: React.CSSProperties = { border: '1px solid var(--border-default)', padding: '.25rem .5rem', textAlign: 'left' }

function Notice({ children }: { children: React.ReactNode }): React.ReactElement {
  return (
    <div role="note" data-testid="preview-notice" style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
      {children}
    </div>
  )
}

function renderBlock(block: unknown, index: number): React.ReactElement {
  if (!isObj(block)) return <Notice key={index}>Unsupported block (index {index})</Notice>
  switch (block.type) {
    case 'page':
      return <React.Fragment key={index} />
    case 'text': {
      const text = str(block.text)
      if (text === null) return <Notice key={index}>Unsupported block (index {index})</Notice>
      return (
        <p key={index} data-testid="preview-text" style={{ margin: '0 0 .5rem' }}>
          {text}
        </p>
      )
    }
    case 'field': {
      return (
        <div key={index} data-testid="preview-field" style={{ marginBottom: '.5rem' }}>
          {str(block.label) ?? str(block.field_name) ?? '?'}: {placeholder(block.entity_type, block.field_name)}
          {block.show_if_nonempty === true && (
            <small data-testid="preview-hidden-marker"> (hidden when empty)</small>
          )}
        </div>
      )
    }
    case 'table': {
      const columns = Array.isArray(block.columns) ? block.columns.filter(isObj) : []
      return (
        <table
          key={index}
          data-testid="preview-table"
          style={{ borderCollapse: 'collapse', width: '100%', marginBottom: '.5rem', fontSize: '.85rem' }}
        >
          <thead>
            <tr>
              {columns.map((c, i) => (
                <th key={i} style={cell}>
                  {str(c.header) ?? str(c.field_name) ?? '?'}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {[0, 1, 2].map((r) => (
              <tr key={r}>
                {columns.map((c, i) => (
                  <td key={i} style={cell}>
                    {placeholder(block.entity_type, c.field_name)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      )
    }
    case 'spacer':
      return <div key={index} data-testid="preview-spacer" aria-hidden style={{ height: `${spacerHeight(block.height_mm)}mm` }} />
    default:
      return <Notice key={index}>Unsupported block (index {index})</Notice>
  }
}

export function PrintLayoutPreview({ layout }: { layout: unknown }): React.ReactElement {
  if (!isObj(layout) || !Array.isArray(layout.blocks)) {
    return (
      <div data-testid="print-preview">
        <Notice>Layout cannot be previewed: expected an object with a blocks list</Notice>
      </div>
    )
  }
  const blocks: unknown[] = layout.blocks
  const page = blocks.find((b): b is Obj => isObj(b) && b.type === 'page')
  const sizeRaw = page ? str(page.size) : null
  const size = sizeRaw !== null && sizeRaw.length <= 16 ? sizeRaw : 'A4'
  const width = size === 'Letter' ? '216mm' : '210mm'
  return (
    <div data-testid="print-preview">
      <div style={{ fontSize: '.75rem', color: 'var(--text-secondary)' }}>Page: {size}</div>
      <div
        style={{
          width,
          maxWidth: '100%',
          minHeight: '12rem',
          padding: '1rem',
          background: 'var(--surface-page)',
          border: '1px solid var(--border-default)',
        }}
      >
        {blocks.map((b, i) => renderBlock(b, i))}
      </div>
    </div>
  )
}
