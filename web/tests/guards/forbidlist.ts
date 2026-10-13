// GRD-UI-01: Single source of truth for all banned patterns.
// No other file under web/tests/guards/ may define RegExp literals.

type Applicability = 'source' | 'bundle' | 'both'

interface GuardPattern {
  /** Unique kebab-case identifier used in violation reports and fixture file names. */
  name: string
  /** The regular expression applied to file content. No regex literals appear outside this file. */
  regex: RegExp
  /** Which scan phases apply this pattern. */
  appliesTo: Applicability
  /**
   * Workspace-relative paths excluded from enforcement.
   * Compared with String.startsWith against the normalised forward-slash file path.
   */
  allowedPaths: string[]
  /** Directive ID or requirement ID that this pattern defends. Must be non-empty. */
  rationale: string
}

export type { GuardPattern, Applicability }

export const PATTERNS: GuardPattern[] = [
  {
    name: 'msw-import',
    regex: /import\s+\S.*from\s+['"]msw(?:\/[a-z]+)?['"]|setupServer\b/,
    appliesTo: 'both',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-2',
  },
  {
    name: 'http-mock-adapter',
    regex: /import\s+\S.*from\s+['"]axios-mock-adapter['"]|new\s+MockAdapter\b/,
    appliesTo: 'both',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-2',
  },
  {
    name: 'raw-fetch-outside-client',
    regex: /\bfetch\(|\baxios\(/,
    appliesTo: 'source',
    allowedPaths: ['web/src/api/client.ts'],
    rationale: 'CMP-UI-02',
  },
  {
    // Catches raw colour literals anywhere in TS/TSX source and the built bundle.
    // web/src/styles/tokens.css is allowedPaths-exempt. Negative lookbehind on rgba?/hsla?
    // prevents matching zero-arg calls from colour-manipulation libraries.
    //
    // GH #2451 (Q-1089): an issue reference in a comment ("// Q-1074 / GH #2431", "/* #2440 */",
    // a JSDoc " * #2432" line) is not a colour. The first two lookbehinds exempt a match that
    // has a line comment or block-comment opener earlier on the same line, or that sits on a
    // JSDoc continuation line. Digit-only colours in code ('#000') are still matched: the
    // exemption needs a comment marker before the token, not a digit-only shape.
    // Known limit: a colour that follows a '//' inside a string on the same line
    // (e.g. "url('https://x') + '#000'") is exempted; it is not seen by this pattern.
    name: 'literal-colour',
    regex: /(?<!(?:\/\/|\/\*)[^\n]*)(?<!(?:^|\n)[ \t]*\*[^\n]*)(?:#[0-9a-fA-F]{3,8}\b|(?<![.a-zA-Z0-9_$])rgba?\([^)]+\)|(?<![.a-zA-Z0-9_$])hsla?\([^)]+\))/,
    appliesTo: 'both',
    allowedPaths: [
      'web/src/styles/tokens.css',
      // The app CSS bundle (index-*.js) contains tokens.css CSS injected as a
      // JS string by Vite. tokens.css is the one legitimate home for raw colour
      // values; its compiled representation is equally exempt. The source-scan
      // ensures no application-owned file in web/src/ (outside tokens.css) contains
      // colour literals — that is the binding enforcement layer.
      'web/dist/assets/index-',
      // Third-party vendor bundle: ReactFlow/CodeMirror contain colour literals
      // (defaultMarkerColor, CM base theme) that cannot use CSS variables.
      'web/dist/assets/vendor-',
    ],
    rationale: 'CMP-UI-06',
  },
  {
    name: 'native-confirm',
    regex: /window\.(confirm|alert|prompt)\(/,
    appliesTo: 'source',
    // PropertyPanel.tsx uses window.confirm — tracked as existing exception
    allowedPaths: ['web/src/components/canvas/PropertyPanel.tsx'],
    rationale: 'CMP-UI-02',
  },
  {
    name: 'tenant-slug-in-source',
    // Matches hard-coded tenant slug string literals (known slugs for this platform)
    regex: /['"](?:swiftroute|vortex(?:-mfg|-manufacturing)?|meridian(?:-capital)?|acme(?:-test|-prod)?)\b/,
    appliesTo: 'source',
    // Test fixtures legitimately use tenant slugs — exempted by directory
    allowedPaths: [
      'web/src/auth/buildRedirectArgs.test.ts',
      'web/src/auth/tenantConfig.test.ts',
      'web/src/components/layout/__tests__/',
      'web/src/pages/admin/tenants/__tests__/',
      'web/src/pages/definitions/__tests__/',
      'web/src/pages/instances/__tests__/',
    ],
    rationale: 'CAC-UI-01',
  },
  {
    name: 'inline-query-key',
    regex: /queryKey\s*:\s*\[/,
    appliesTo: 'source',
    allowedPaths: ['web/src/api/queryKeys.ts'],
    rationale: 'CAC-UI-01',
  },
  {
    name: 'inline-stale-time',
    regex: /staleTime\s*:\s*\d/,
    appliesTo: 'source',
    // main.tsx sets global default staleTime in QueryClient config — legitimate
    allowedPaths: ['web/src/api/queryKeys.ts', 'web/src/main.tsx'],
    rationale: 'CAC-UI-01',
  },
  {
    // Matches files that call useQuery() without importing a query-state boundary.
    // Apply to whole-file content: the ^ anchor + negative lookahead spans multiple lines.
    name: 'missing-query-state-boundary',
    regex: /^(?![\s\S]*(?:QueryStateBoundary|ErrorBoundary|Suspense))[\s\S]*useQuery\(/,
    appliesTo: 'source',
    // Custom hooks return query results for callers to wrap; the named components here are
    // layout/panel components that handle their own loading states inline.
    allowedPaths: [
      'web/src/hooks/',
      'web/src/components/layout/AppShell.tsx',
      'web/src/components/webhooks/WebhookSubscriptionDetailPanel.tsx',
    ],
    rationale: 'GRD-UI-02',
  },
  {
    name: 'test-only-or-skip',
    regex: /\bit\.only\s*\(|\btest\.only\s*\(|\bdescribe\.only\s*\(|\bit\.skip\s*\(|\btest\.skip\s*\(/,
    appliesTo: 'source',
    allowedPaths: [],
    rationale: 'DIRECTIVE T-1',
  },
  {
    // ISS-0813: Only /api/v1/admin/services is mounted under the /admin prefix in
    // lib/letflow/plugs/api_pipeline.ex. Any other /api/v1/admin/... path literal is
    // a dead prefix — the same class of defect that produced ISS-0736, ISS-0782, and
    // ISS-0765. This guard fires when /api/v1/admin/ appears NOT followed by "services".
    name: 'dead-admin-prefix',
    regex: /\/api\/v1\/admin\/(?!services)/,
    appliesTo: 'source',
    allowedPaths: [
      // Only legitimate user of /api/v1/admin/ in web/src/api/
      'web/src/api/services.ts',
      // Test files document historical violations in comments and assertion strings
      'web/src/api/__tests__/',
    ],
    rationale: 'ISS-0813',
  },
]
