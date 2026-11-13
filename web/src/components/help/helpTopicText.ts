/** helpTopicText — T-1560. The fixed shape of one static help topic (1 purpose, exactly 3 tasks, exactly 3
 *  refusals) and its flattening into message-catalogue ids `<mod>.help.<topic>.<part>`, so the modules' en/ru/kk
 *  completeness checks cover every string. */
export interface HelpTopicText {
  title: string
  purpose: string
  tasks: [string, string, string]
  refusals: [HelpRefusal, HelpRefusal, HelpRefusal]
}
export interface HelpRefusal {
  title: string
  body: string
}
export interface HelpCommonText {
  link: string
  close: string
  back: string
  purpose: string
  tasks: string
  refusals: string
}

export const HELP_PARTS = ['title', 'purpose', 'task1', 'task2', 'task3', 'ref1.title', 'ref1.body', 'ref2.title', 'ref2.body', 'ref3.title', 'ref3.body'] as const

export function helpIds(mod: string, topic: string): string[] {
  return HELP_PARTS.map((p) => `${mod}.help.${topic}.${p}`)
}

/** The catalogue entries of one locale: module-wide labels plus every topic. */
export function flattenHelp(mod: string, common: HelpCommonText, topics: Record<string, HelpTopicText>): Record<string, string> {
  const out: Record<string, string> = {
    [`${mod}.help.link`]: common.link,
    [`${mod}.help.close`]: common.close,
    [`${mod}.help.back`]: common.back,
    [`${mod}.help.h.purpose`]: common.purpose,
    [`${mod}.help.h.tasks`]: common.tasks,
    [`${mod}.help.h.refusals`]: common.refusals,
  }
  for (const [topic, t] of Object.entries(topics)) {
    out[`${mod}.help.${topic}.title`] = t.title
    out[`${mod}.help.${topic}.purpose`] = t.purpose
    t.tasks.forEach((task, i) => (out[`${mod}.help.${topic}.task${i + 1}`] = task))
    t.refusals.forEach((r, i) => {
      out[`${mod}.help.${topic}.ref${i + 1}.title`] = r.title
      out[`${mod}.help.${topic}.ref${i + 1}.body`] = r.body
    })
  }
  return out
}

/** Reads one topic back out of a `formatMessage`-style function. Only called with a topic from the closed list. */
export function readTopic(mod: string, topic: string, t: (id: string) => string): HelpTopicText {
  const g = (p: string) => t(`${mod}.help.${topic}.${p}`)
  return {
    title: g('title'),
    purpose: g('purpose'),
    tasks: [g('task1'), g('task2'), g('task3')],
    refusals: [
      { title: g('ref1.title'), body: g('ref1.body') },
      { title: g('ref2.title'), body: g('ref2.body') },
      { title: g('ref3.title'), body: g('ref3.body') },
    ],
  }
}
