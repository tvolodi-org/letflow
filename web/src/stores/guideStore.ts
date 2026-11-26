/** guideStore -- T-2805: whether the designer guide panel is open, and which section it opens at
 *  (an anchor id of docs/designer-guide.md, such as `sec-notification-step`). */
import { create } from 'zustand'

interface GuideState {
  open: boolean
  section: string | null
  openGuide: (section?: string) => void
  closeGuide: () => void
}

export const useGuideStore = create<GuideState>((set) => ({
  open: false,
  section: null,
  openGuide: (section) => set({ open: true, section: section ?? null }),
  closeGuide: () => set({ open: false, section: null }),
}))
