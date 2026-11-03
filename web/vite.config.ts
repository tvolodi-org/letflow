import { defineConfig, type Plugin } from 'vite'
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

// Task S0d — dev server only (apply: 'serve'; never in a build). Pages under /__harness/ get a hidden iframe whose
// document the server holds back until the harness page says it has drawn (/__harness-ready, an image request),
// or 10 s pass. A page's load event waits for it, so `firefox --screenshot` (which fires on load) sees the screen.
function harnessGatePlugin(): Plugin {
  const waiting: Array<() => void> = []
  return {
    name: 'harness-gate',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = req.url ?? ''
        if (url.startsWith('/__harness-ready')) {
          while (waiting.length) waiting.pop()?.()
          res.statusCode = 204
          res.end()
          return
        }
        if (url.startsWith('/__harness-wait')) {
          const release = () => {
            clearTimeout(timer)
            if (!res.writableEnded) {
              res.setHeader('Content-Type', 'text/html')
              res.end('<!doctype html>')
            }
          }
          const timer = setTimeout(release, 10_000)
          waiting.push(release)
          return
        }
        next()
      })
    },
    transformIndexHtml(_html, ctx) {
      if (!ctx.originalUrl?.startsWith('/__harness/')) return []
      return [{ tag: 'iframe', attrs: { src: '/__harness-wait', hidden: true, title: 'harness gate' }, injectTo: 'body-prepend' }]
    },
  }
}

export default defineConfig({
  plugins: [react(), exprManifestPlugin(), harnessGatePlugin()],
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
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
