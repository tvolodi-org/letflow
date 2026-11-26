/** DeclaredVariablesContext — T-2811 (designer D1). The variables of the process, as the Edit-diagram screen holds them:
 *  the list, and the one way to add a variable. The step editors read it to offer a PICKER instead of a free name; with
 *  no provider (a screen that does not know the variables) they keep their plain name field. */
import { createContext, useContext } from 'react'
import type { DeclaredVariable } from '@/types/api'
import type { AddVariableRefusal, VariableType } from '@/utils/canvas/declaredVariables'

export interface DeclaredVariables {
  variables: DeclaredVariable[]
  /** Adds a variable; returns the refusal, or null when it was added. */
  add: (name: string, type: VariableType) => AddVariableRefusal | null
}

export const DeclaredVariablesContext = createContext<DeclaredVariables | null>(null)

export const useDeclaredVariables = () => useContext(DeclaredVariablesContext)
