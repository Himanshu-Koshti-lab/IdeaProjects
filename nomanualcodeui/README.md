# nomanualcodeui (frontend)

The web frontend for nomanualcode. It is a React 19 single-page app built with Vite and served in production by a small Express server.

> **Status:** `App.jsx` currently renders an empty fragment. It is a blank shell ready for UI work.

## Getting started

```sh
npm install
npm run dev
```

Open <http://localhost:5173>. Edits hot-reload.

## Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Start the Vite dev server with HMR (port 5173) |
| `npm run build` | Produce an optimized build in `dist/` |
| `npm run preview` | Serve `dist/` with Vite's preview server |
| `npm run lint` | Run ESLint |
| `npm start` | Serve `dist/` with the Express server ([server.js](server.js)) |
| `npm run serve` | `build` then `start` |

## Production server

[server.js](server.js) is an Express 5 app that:

- listens on `PORT` (default `3000`)
- exposes `GET /api/health` → `{ "status": "ok" }`
- proxies `/api/persons/**` to the backend (see below)
- serves `dist/assets/*` with long-lived immutable caching (Vite hashes these filenames)
- falls back to `index.html` (with `Cache-Control: no-cache`) for every other GET, so client-side routing works

```sh
npm run serve
# or, with a custom port
PORT=8000 npm start        # PowerShell: $env:PORT=8000; npm start
```

## Talking to the backend

The Spring Boot API ([../nomanualcode](../nomanualcode/README.md)) runs on port 8080. Both servers proxy `/api/persons/**` to it, so the browser makes only same-origin requests and **CORS never comes into play**. Use relative URLs in components:

```js
const res = await fetch('/api/persons', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ firstName: 'Grace', lastName: 'Hopper', email: 'grace@example.com' }),
})
```

**Development:** [vite.config.js](vite.config.js)

```js
server: {
  proxy: {
    '/api/persons': process.env.API_URL || 'http://localhost:8080',
  },
},
```

**Production:** [server.js](server.js). It is registered before the SPA fallback and forwards the method, query string, body, and the `Content-Type` and `Accept` headers. It passes back the status, `Content-Type` and `Location`. If the backend can't be reached, it returns `502`.

```js
app.use('/api/persons', express.raw({ type: '*/*' }), async (req, res) => {
  const upstream = await fetch(apiUrl + req.originalUrl, { method: req.method, headers, body })
  // ...copy status + headers, send body
})
```

Point either server at a different backend with `API_URL`:

```sh
API_URL=http://api.internal:8080 npm run serve
# PowerShell: $env:API_URL='http://api.internal:8080'; npm run serve
```

## Project layout

```
index.html          # HTML entry, mounts #root
src/
├── main.jsx        # React root (StrictMode)
├── App.jsx         # top-level component
├── App.css
└── index.css
public/             # static files copied as-is (favicon, icons)
server.js           # production Express server
vite.config.js
eslint.config.js
```
