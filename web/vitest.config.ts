import { defineConfig, mergeConfig } from 'vitest/config'
import viteConfig from './vite.config'

// Pool floor: the machine-wide test runner caps workers with VITEST_MAX_FORKS /
// VITEST_MAX_THREADS; without an explicit minimum, vitest 2 derives one from the CPU count
// and fails with "minThreads and maxThreads must not conflict" when the cap is below it.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      poolOptions: {
        forks: { minForks: 1 },
        threads: { minThreads: 1 },
      },
    },
  }),
)
