import { defineConfig, mergeConfig } from 'vitest/config'
import viteConfig from './vite.config'

// The machine-wide test runner caps workers with VITEST_MAX_FORKS / VITEST_MAX_THREADS; vite.config.ts maps them to
// vitest 5's maxWorkers (poolOptions and minForks/minThreads no longer exist, so there is no pool floor to set).
export default mergeConfig(viteConfig, defineConfig({ test: {} }))
