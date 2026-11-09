/** HelpTopicView — T-1560. Pure view of one static help topic: purpose, three common tasks, what refusals mean.
 *  Plain text only (no markdown, no HTML, no images). */
import { Link } from 'react-router-dom'
import { PageHeader } from '@/components/ui/PageHeader'
import type { HelpTopicText } from './helpTopicText'

export interface HelpTopicViewProps {
  text: HelpTopicText
  headings: { purpose: string; tasks: string; refusals: string }
  back: { to: string; label: string }
}

export function HelpTopicView({ text, headings, back }: HelpTopicViewProps) {
  return (
    <div className="lf-help" data-testid="help-topic">
      <PageHeader title={text.title} actions={<Link to={back.to} className="lf-btn lf-btn--ghost" data-testid="help-back">{back.label}</Link>} />
      <section aria-labelledby="help-purpose">
        <h2 id="help-purpose">{headings.purpose}</h2>
        <p data-testid="help-purpose-text">{text.purpose}</p>
      </section>
      <section aria-labelledby="help-tasks">
        <h2 id="help-tasks">{headings.tasks}</h2>
        <ol data-testid="help-tasks-list">
          {text.tasks.map((task) => (
            <li key={task}>{task}</li>
          ))}
        </ol>
      </section>
      <section aria-labelledby="help-refusals">
        <h2 id="help-refusals">{headings.refusals}</h2>
        <dl data-testid="help-refusals-list">
          {text.refusals.map((r) => (
            <div key={r.title}>
              <dt>{r.title}</dt>
              <dd>{r.body}</dd>
            </div>
          ))}
        </dl>
      </section>
    </div>
  )
}
