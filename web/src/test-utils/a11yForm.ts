/** assertFormAccessible — T-1554. A small jsdom check for the keyboard / screen-reader basics of a form: every control
 *  has an accessible name, every `aria-invalid` control has live error text via `aria-describedby`, nothing steals Tab
 *  order with a positive tabindex, and a `role="grid"` has column headers. Other screens can call it from their tests. */
const nameOf = (el: Element, root: ParentNode): string => {
  const aria = el.getAttribute('aria-label')?.trim()
  if (aria) return aria
  const by = el.getAttribute('aria-labelledby')
  if (by) {
    const text = by.split(/\s+/).map((id) => root.ownerDocument?.getElementById(id)?.textContent ?? document.getElementById(id)?.textContent ?? '').join(' ').trim()
    if (text) return text
  }
  const id = el.getAttribute('id')
  if (id) {
    const label = Array.from(document.querySelectorAll('label')).find((l) => l.htmlFor === id)
    if (label?.textContent?.trim()) return label.textContent.trim()
  }
  const wrap = el.closest('label')
  return wrap?.textContent?.trim() ?? ''
}

export function accessibleFormProblems(root: ParentNode = document.body): string[] {
  const problems: string[] = []
  const describe = (el: Element) => `<${el.tagName.toLowerCase()} name="${el.getAttribute('name') ?? ''}" id="${el.id}">`
  root.querySelectorAll('input, select, textarea').forEach((el) => {
    if (el.getAttribute('type') === 'hidden' || el.getAttribute('aria-hidden') === 'true') return
    if (nameOf(el, root) === '') problems.push(`no accessible name: ${describe(el)}`)
  })
  root.querySelectorAll('[aria-invalid="true"]').forEach((el) => {
    const ids = (el.getAttribute('aria-describedby') ?? '').split(/\s+/).filter(Boolean)
    const text = ids.map((id) => document.getElementById(id)?.textContent?.trim() ?? '').join('')
    if (text === '') problems.push(`aria-invalid without error text: ${describe(el)}`)
  })
  root.querySelectorAll('[tabindex]').forEach((el) => {
    if (Number(el.getAttribute('tabindex')) > 0) problems.push(`positive tabindex: ${describe(el)}`)
  })
  root.querySelectorAll('[role="grid"]').forEach((el) => {
    if (el.querySelector('[role="columnheader"]') === null) problems.push('grid without columnheader')
  })
  return problems
}

export function assertFormAccessible(root: ParentNode = document.body): void {
  const problems = accessibleFormProblems(root)
  if (problems.length > 0) throw new Error(`form is not accessible:\n${problems.join('\n')}`)
}
