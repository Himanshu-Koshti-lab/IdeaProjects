import react from '@vitejs/plugin-react'
import process from 'node:process'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // Forward API calls to the Spring Boot backend so the browser stays same-origin (no CORS).
    proxy: {
      '/api/persons': process.env.API_URL || 'http://localhost:8080',
    },
  },
})
