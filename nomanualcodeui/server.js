import express from 'express'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const distDir = path.join(__dirname, 'dist')
const port = process.env.PORT || 3000
const apiUrl = process.env.API_URL || 'http://localhost:8080'

const app = express()

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok' })
})

// Forward API calls to the Spring Boot backend so the browser stays same-origin (no CORS).
app.use('/api/persons', express.raw({ type: '*/*' }), async (req, res) => {
  const headers = {}
  for (const name of ['content-type', 'accept']) {
    if (req.get(name)) headers[name] = req.get(name)
  }

  try {
    const upstream = await fetch(apiUrl + req.originalUrl, {
      method: req.method,
      headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : req.body,
    })

    res.status(upstream.status)
    for (const name of ['content-type', 'location']) {
      const value = upstream.headers.get(name)
      if (value) res.set(name, value)
    }
    res.send(Buffer.from(await upstream.arrayBuffer()))
  } catch (err) {
    console.error(`API proxy error: ${err.message}`)
    res.status(502).json({ error: 'Backend unavailable' })
  }
})

// Hashed build assets can be cached aggressively; index.html must not be.
app.use(
  '/assets',
  express.static(path.join(distDir, 'assets'), { immutable: true, maxAge: '1y' }),
)
app.use(express.static(distDir, { index: false }))

// SPA fallback: let the client-side app handle any other GET route.
app.get('/{*splat}', (req, res) => {
  res.set('Cache-Control', 'no-cache')
  res.sendFile(path.join(distDir, 'index.html'))
})

app.listen(port, () => {
  console.log(`Server listening on http://localhost:${port}`)
})
