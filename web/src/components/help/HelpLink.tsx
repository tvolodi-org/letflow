/** HelpLink — T-1560. A ghost link in a page header that opens the static help page of the screen. The label comes
 *  from the caller's message catalogue, so this component holds no text. */
import { Link } from 'react-router-dom'

export function HelpLink({ to, label }: { to: string; label: string }) {
  return (
    <Link to={to} className="lf-btn lf-btn--ghost" data-testid="help-link">
      {label}
    </Link>
  )
}
