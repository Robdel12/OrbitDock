import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'

export default defineConfig({
  plugins: [preact()],
  resolve: { alias: { '@': '/src' } },
  server: {
    port: 3020,
    host: '0.0.0.0',
    proxy: {
      '/api': 'http://localhost:4000',
      '/ws': { target: 'ws://localhost:4000', ws: true },
      '/health': 'http://localhost:4000',
    },
  },
})
