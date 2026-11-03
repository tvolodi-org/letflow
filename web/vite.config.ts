import { type Plugin } from 'vite'
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'
import { readFileSync } from 'fs'

// REQ-293 §8.3 — the ONLY way the REQ-290 corpus manifest/version-marker data
// reaches the client: a build-time virtual module, not a runtime fetch and not a
// new Phoenix route. Reads priv/expr_conformance/manifest.json (repo-root, a
// sibling of web/) at every dev-server request and every production build, so
// the bundled value is always exactly the current file content by construction
// — no second checked-in copy to drift. See
// lib/letflow/design/req293-typescript-expr-evaluator.md §8.3.
const EXPR_MANIFEST_VIRTUAL_ID = 'virtual:expr-manifest'
const EXPR_MANIFEST_RESOLVED_ID = '\0' + EXPR_MANIFEST_VIRTUAL_ID

function exprManifestPlugin(): Plugin {
  const manifestPath = resolve(__dirname, '..', 'priv', 'expr_conformance', 'manifest.json')

  return {
    name: 'expr-manifest',
    resolveId(id) {
      if (id === EXPR_MANIFEST_VIRTUAL_ID) return EXPR_MANIFEST_RESOLVED_ID
      return null
    },
    load(id) {
      if (id !== EXPR_MANIFEST_RESOLVED_ID) return null
      const manifest = readFileSync(manifestPath, 'utf-8')
      return `export default ${manifest}`
    },
    configureServer(server) {
      server.watcher.add(manifestPath)
      server.watcher.on('change', (changedPath) => {
        if (changedPath === manifestPath) {
          const mod = server.moduleGraph.getModuleById(EXPR_MANIFEST_RESOLVED_ID)
          if (mod) server.moduleGraph.invalidateModule(mod)
        }
      })
    },
  }
}

// Task S0e: the tenant-colour contrast check needs the fixed Letflow values (paper-raised and the default
// on-current of each theme). They are read from the generated tokens.css at build time, never copied by
// hand. (`?raw` on a .css file is empty under vitest, hence a virtual module.)
const TENANT_THEME_VIRTUAL_ID = 'virtual:letflow-theme-tokens'

function themeTokensPlugin(): Plugin {
  const cssPath = resolve(__dirname, 'src', 'styles', 'tokens.css')
  const pick = (name: string, last: boolean): string => {
    const css = readFileSync(cssPath, 'utf-8')
    const all = [...css.matchAll(new RegExp(`--${name}:\\s*(?:var\\([^,]+,\\s*)?(#[0-9a-fA-F]{6})`, 'g'))]
    const m = last ? all[all.length - 1] : all[0]
    if (!m) throw new Error(`tokens.css does not define --${name}`)
    return m[1]
  }
  return {
    name: 'letflow-theme-tokens',
    resolveId(id) {
      return id === TENANT_THEME_VIRTUAL_ID ? '\0' + id : null
    },
    load(id) {
      if (id !== '\0' + TENANT_THEME_VIRTUAL_ID) return null
      // First occurrence in tokens.css is the light theme, the last one the dark theme.
      return `export default ${JSON.stringify({
        paperRaisedLight: pick('paper-raised', false),
        paperRaisedDark: pick('paper-raised', true),
        onCurrentLight: pick('on-current', false),
        onCurrentDark: pick('on-current', true),
      })}`
    },
  }
}

export default defineConfig({
  plugins: [react(), exprManifestPlugin(), themeTokensPlugin()],
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
  test: {
    // lf.sh caps workers with VITEST_MAX_FORKS/THREADS; a minimum above that cap makes tinypool throw.
    poolOptions: { forks: { minForks: 1 }, threads: { minThreads: 1 } },
  },
  build: {
    rollupOptions: {
      output: {
        // Split third-party dependencies into vendor-* chunks so the literal-colour
        // bundle guard can exempt them without blanketing the application code.
        manualChunks(id) {
          if (id.includes('node_modules')) return 'vendor'
        },
      },
    },
  },
  server: {
    port: Number(process.env.VITE_PORT) || 5173,
    proxy: {
      '/api': {
        target: process.env.VITE_API_BASE_URL || 'http://localhost:4000',
        changeOrigin: true,
      },
      '/health': {
        target: process.env.VITE_API_BASE_URL || 'http://localhost:4000',
        changeOrigin: true,
      },
    },
  },
})
