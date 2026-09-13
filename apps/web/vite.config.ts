import {
  readFileSync,
} from 'node:fs'
import {
  fileURLToPath,
} from 'node:url'

import react from '@vitejs/plugin-react'
import {
  defineConfig,
} from 'vite'

function readSecret(
  relativeUrl: string,
): string {
  return readFileSync(
    fileURLToPath(
      new URL(
        relativeUrl,
        import.meta.url,
      ),
    ),
    'utf8',
  ).trim()
}

export default defineConfig({
  plugins: [
    react(),
  ],

  server: {
    host: '0.0.0.0',
    port: 5173,

    proxy: {
      '/api': {
        target: 'https://127.0.0.1:8443',
        secure: false,
        changeOrigin: false,

        configure(proxy) {
          const apiKey =
            readSecret(
              '../../secrets/api_key',
            )

          const apiSecret =
            readSecret(
              '../../secrets/api_secret',
            )

          const credentials =
            Buffer
              .from(
                `${apiKey}:${apiSecret}`,
                'utf8',
              )
              .toString(
                'base64',
              )

          proxy.on(
            'proxyReq',
            (request) => {
              request.setHeader(
                'Host',
                'api.heymail.test:8443',
              )

              request.setHeader(
                'Authorization',
                `Basic ${credentials}`,
              )
            },
          )
        },
      },
    },
  },
})
