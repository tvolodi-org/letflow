/** Context that carries the ListDetail back / close handler to the DetailHeader inside its detail panel. */
import { createContext, useContext } from 'react'

export const ListDetailBackContext = createContext<(() => void) | null>(null)
export const useListDetailBack = () => useContext(ListDetailBackContext)
