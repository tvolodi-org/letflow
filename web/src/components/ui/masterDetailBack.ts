/** Context that carries the MasterDetail back handler to the DetailHeader inside its detail panel. */
import { createContext, useContext } from 'react'

export const MasterDetailBackContext = createContext<(() => void) | null>(null)
export const useMasterDetailBack = () => useContext(MasterDetailBackContext)
