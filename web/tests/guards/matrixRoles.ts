import { join } from 'node:path'

const AUTHORIZATION_EX_PATH = join(__dirname, '..', '..', '..', 'lib', 'letflow', 'api', 'authorization.ex')

/** The role names in lib/letflow/api/authorization.ex's `@roles` module attribute. */
export function extractMatrixRoles(source: string): string[] {
  const match = source.match(/@roles \[([^\]]+)\]/)
  if (!match) {
    throw new Error(
      `Could not find "@roles [...]" in ${AUTHORIZATION_EX_PATH} -- has Letflow.Api.Authorization been restructured? Update this guard's extraction to match.`,
    )
  }
  return match[1]
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0)
    .map((entry) => entry.replace(/^:/, ''))
}
