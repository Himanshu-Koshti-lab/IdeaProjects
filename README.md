# nomanualcode

A small full-stack workspace made of two independent projects:

| Project | Stack | Default port | Purpose |
|---|---|---|---|
| [nomanualcode/](nomanualcode/) | Java 26, Spring Boot 4.1, Spring Data JPA, H2 | `8080` | REST API for managing `Person` records |
| [nomanualcodeui/](nomanualcodeui/) | React 19, Vite 8, Express 5 | `5173` (dev) / `3000` (prod) | Web frontend (currently an empty React shell) |

## Quick start

Run each project in its own terminal.

**Backend**

```sh
cd nomanualcode
./gradlew bootRun          # Windows: gradlew.bat bootRun
```

Try it out: <http://localhost:8080/api/persons>

**Frontend**

```sh
cd nomanualcodeui
npm install
npm run dev
```

Open <http://localhost:5173>.

## Prerequisites

- **JDK 26.** Gradle's toolchain support can download it for you if it isn't installed.
- **Node.js 20.19+ or 22.12+** (required by Vite 8) and npm.
- **Docker** (optional), needed only if you add Testcontainers services to the backend tests.

## Connecting the UI to the API

The frontend proxies `/api/persons/**` to the backend in both dev and production. The browser only ever talks to the frontend's own origin, so **no CORS configuration is needed** on the Spring side. Components just call relative URLs:

```js
const persons = await fetch('/api/persons').then((r) => r.json())
```

| Mode | Proxy lives in | Backend URL |
|---|---|---|
| `npm run dev` | [nomanualcodeui/vite.config.js](nomanualcodeui/vite.config.js) (`server.proxy`) | `API_URL` env var, default `http://localhost:8080` |
| `npm run serve` / `npm start` | [nomanualcodeui/server.js](nomanualcodeui/server.js) (Express route) | `API_URL` env var, default `http://localhost:8080` |

Start the backend first. If it isn't reachable, the Express proxy returns `502 {"error":"Backend unavailable"}`.

See each project's README for details:

- [nomanualcode/README.md](nomanualcode/README.md): API endpoints, database, tests
- [nomanualcodeui/README.md](nomanualcodeui/README.md): npm scripts, production server
