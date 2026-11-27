import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import { execFileSync } from 'node:child_process'
import { version } from './package.json'

function displayVersion() {
  try {
    const revision = execFileSync('git', ['rev-parse', '--short=7', 'HEAD'], {
      cwd: new URL('.', import.meta.url), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    return /^[0-9a-f]{7,40}$/.test(revision) ? `${version}-${revision}` : version
  } catch {
    // Packaged Docker builds have no Git checkout and use the release version.
    return version
  }
}

export default defineConfig({
  define: { __APP_VERSION__: JSON.stringify(displayVersion()) },
  plugins: [react()],
  test: { setupFiles: ['./src/testSetup.ts'] },
  server: {
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8000',
        changeOrigin: false,
      },
    },
  },
})
