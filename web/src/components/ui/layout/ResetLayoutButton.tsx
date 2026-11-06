/** Reset layout — a ghost button that forgets the remembered pane and column sizes of one screen (`screens.<id>`). */
import { Button } from '../Button'
import { useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { useLayoutMessages } from './layoutMessages'

export function ResetLayoutButton({ screen }: { screen: string }) {
  const store = useLayoutPrefs()
  const lm = useLayoutMessages()
  return (
    <Button variant="ghost" onClick={() => store.resetScreen(screen)} data-testid="reset-layout">
      {lm.resetLayout}
    </Button>
  )
}
