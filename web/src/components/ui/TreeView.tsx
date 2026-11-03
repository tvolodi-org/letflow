/** TreeView — `role=tree` with a roving tabindex (README "Trees").
 *
 *  Controlled: the caller owns `selectedId` and `expandedIds`. Keys: Up/Down
 *  move, Right opens or goes to the first child, Left closes or goes to the
 *  parent, Home/End, Enter/Space select, a letter jumps to the next visible
 *  node whose name starts with it. Retired nodes are hidden unless
 *  `showRetired`. A name or code that does not fit is cut by CSS and its full
 *  text is in `title`. `--lvl` (the indent level) is the one inline style: it
 *  is the input of the `.lf-tree__row` indent rule, not a colour or a length.
 */

import React, { useEffect, useMemo, useRef, useState } from 'react'
import { ChevronDown } from 'lucide-react'
import { StatusPill } from './StatusPill'

export interface TreeNode {
  id: string
  name: string
  code?: string
  /** Right-hand count or short note. */
  meta?: React.ReactNode
  retired?: boolean
  children?: TreeNode[]
  /** Children are being fetched: an expanded node shows a loading row. */
  loading?: boolean
}

export interface TreeViewProps {
  nodes: TreeNode[]
  selectedId?: string | null
  expandedIds: ReadonlyArray<string> | ReadonlySet<string>
  onSelect: (id: string) => void
  onToggle: (id: string) => void
  showRetired?: boolean
  'aria-label'?: string
  labels?: { expand: string; collapse: string; retired: string; loading: string }
}

const DEFAULT_LABELS = { expand: 'Expand', collapse: 'Collapse', retired: 'Retired', loading: 'Loading…' }

interface FlatNode {
  node: TreeNode
  level: number
  parentId: string | null
  expandable: boolean
  expanded: boolean
}

export function TreeView(props: TreeViewProps): React.ReactElement {
  const { nodes, selectedId = null, onSelect, onToggle, showRetired = false } = props
  const labels = props.labels ?? DEFAULT_LABELS
  const expandedSet = useMemo(() => new Set(props.expandedIds), [props.expandedIds])
  const rootRef = useRef<HTMLDivElement>(null)
  const [focusId, setFocusId] = useState<string | null>(null)
  const moveFocus = useRef(false)

  const visible = useMemo(() => {
    const out: FlatNode[] = []
    const walk = (list: TreeNode[], level: number, parentId: string | null): void => {
      for (const node of list) {
        if (node.retired && !showRetired) continue
        const kids = node.children ?? []
        const expandable = kids.length > 0 || node.loading === true
        const expanded = expandable && expandedSet.has(node.id)
        out.push({ node, level, parentId, expandable, expanded })
        if (expanded) walk(kids, level + 1, node.id)
      }
    }
    walk(nodes, 0, null)
    return out
  }, [nodes, showRetired, expandedSet])

  const tabbableId =
    [focusId, selectedId].find((id) => id !== null && visible.some((v) => v.node.id === id)) ??
    visible[0]?.node.id ??
    null

  useEffect(() => {
    if (!moveFocus.current || focusId === null) return
    moveFocus.current = false
    rootRef.current?.querySelector<HTMLElement>(`[data-node-id="${CSS.escape(focusId)}"]`)?.focus()
  }, [focusId])

  function focusNode(id: string): void {
    moveFocus.current = true
    setFocusId(id)
  }

  function handleKeyDown(event: React.KeyboardEvent, index: number): void {
    const current = visible[index]
    if (!current) return
    const { node } = current
    switch (event.key) {
      case 'ArrowDown':
        if (visible[index + 1]) focusNode(visible[index + 1].node.id)
        break
      case 'ArrowUp':
        if (index > 0) focusNode(visible[index - 1].node.id)
        break
      case 'Home':
        focusNode(visible[0].node.id)
        break
      case 'End':
        focusNode(visible[visible.length - 1].node.id)
        break
      case 'ArrowRight':
        if (current.expandable && !current.expanded) onToggle(node.id)
        else if (current.expanded && visible[index + 1]?.parentId === node.id) focusNode(visible[index + 1].node.id)
        break
      case 'ArrowLeft':
        if (current.expanded) onToggle(node.id)
        else if (current.parentId !== null) focusNode(current.parentId)
        break
      case 'Enter':
      case ' ':
        onSelect(node.id)
        break
      default: {
        if (event.key.length !== 1 || event.ctrlKey || event.metaKey || event.altKey) return
        const letter = event.key.toLocaleLowerCase()
        const order = [...visible.slice(index + 1), ...visible.slice(0, index)]
        const hit = order.find((v) => v.node.name.toLocaleLowerCase().startsWith(letter))
        if (!hit) return
        focusNode(hit.node.id)
      }
    }
    event.preventDefault()
  }

  function renderList(list: TreeNode[], level: number): React.ReactNode[] {
    return list
      .filter((node) => showRetired || !node.retired)
      .map((node) => {
        const index = visible.findIndex((v) => v.node.id === node.id)
        const flat = visible[index]
        const kids = node.children ?? []
        const selected = node.id === selectedId
        const code = node.code
        return (
          <div
            key={node.id}
            role="treeitem"
            aria-level={level + 1}
            aria-expanded={flat.expandable ? flat.expanded : undefined}
            aria-selected={selected}
            data-testid="tree-item"
          >
            <div
              className={`lf-tree__row${node.retired ? ' is-retired' : ''}`}
              data-lvl={level}
              data-node-id={node.id}
              style={{ '--lvl': level } as React.CSSProperties}
              aria-selected={selected || undefined}
              tabIndex={node.id === tabbableId ? 0 : -1}
              onClick={() => {
                setFocusId(node.id)
                onSelect(node.id)
              }}
              onFocus={() => setFocusId(node.id)}
              onKeyDown={(event) => {
                if (event.target === event.currentTarget) handleKeyDown(event, index)
              }}
            >
              {flat.expandable ? (
                <button
                  type="button"
                  className="lf-tree__toggle"
                  tabIndex={-1}
                  aria-label={flat.expanded ? labels.collapse : labels.expand}
                  onClick={(event) => {
                    event.stopPropagation()
                    onToggle(node.id)
                  }}
                >
                  <ChevronDown className="lf-icon" aria-hidden="true" />
                </button>
              ) : (
                <span className="lf-tree__leaf" aria-hidden="true" />
              )}
              <span className="lf-tree__label">
                <span className="lf-tree__name" title={node.name}>
                  {node.name}
                </span>
                {code && (
                  <span className="lf-tree__code" title={code}>
                    {code}
                  </span>
                )}
              </span>
              {node.retired ? (
                <StatusPill tone="neutral" glyph="dash">
                  {labels.retired}
                </StatusPill>
              ) : (
                node.meta !== undefined && <span className="lf-tree__meta">{node.meta}</span>
              )}
            </div>
            {flat.expanded && (
              <div role="group">
                {node.loading && kids.length === 0 ? (
                  <div className="lf-tree__row" data-lvl={level + 1} style={{ '--lvl': level + 1 } as React.CSSProperties}>
                    <span className="lf-tree__leaf" aria-hidden="true" />
                    <span className="lf-tree__label lf-muted" role="status">
                      {labels.loading}
                    </span>
                  </div>
                ) : (
                  renderList(kids, level + 1)
                )}
              </div>
            )}
          </div>
        )
      })
  }

  return (
    <div className="lf-tree" role="tree" aria-label={props['aria-label']} ref={rootRef} data-testid="tree-view">
      {renderList(nodes, 0)}
    </div>
  )
}
