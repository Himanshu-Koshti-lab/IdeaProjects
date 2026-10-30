# nomanualcode

A small full-stack workspace made of two independent projects:

| Project | Stack | Default port | Purpose |
|---|---|---|---|
| [nomanualcode/](nomanualcode/) | Java 26, Spring Boot 4.1, Spring Data JPA, H2 | `8080` | REST API for managing `Person` records |
| [nomanualcodeui/](nomanualcodeui/) | React 19, Vite 8, Express 5 | `5173` (dev) / `3000` (prod) | Web frontend (currently an empty React shell) |

## Quick start

Run both servers from the repo root with one command:

```sh
node dev.mjs
```

It starts the backend (`:8080`) and the frontend dev server (`:5173`) with their output prefixed `[api]` / `[ui]`, and installs frontend dependencies on first run. Press **Ctrl+C** to stop both. If either server exits on its own, the other one is stopped too.

Or run each project in its own terminal:

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

## Docker

Each project has its own `Dockerfile`, so the two images can be built and deployed independently.

```sh
docker build -t nomanualcode-backend  ./nomanualcode     # Spring Boot API, port 8080
docker build -t nomanualcode-frontend ./nomanualcodeui   # Express + React build, port 3000
```

Run them anywhere. The frontend only needs to know where the backend is, via `API_URL`:

```sh
docker run -d -p 8080:8080 nomanualcode-backend
docker run -d -p 3000:3000 -e API_URL=http://<backend-host>:8080 nomanualcode-frontend
```

| Image | Env var | Default | Purpose |
|---|---|---|---|
| backend | `SPRING_PROFILES_ACTIVE` | _(none)_ | `json` for one-JSON-object-per-line logs |
| backend | `JAVA_OPTS` | `-XX:MaxRAMPercentage=75` | JVM flags |
| frontend | `API_URL` | `http://localhost:8080` | Backend base URL, as reachable from the frontend container |
| frontend | `PORT` | `3000` | Listen port |

To run both together locally: `docker compose up --build`, then open <http://localhost:3000>.

### Build script and Kubernetes

[build-images.sh](build-images.sh) builds both images with a version tag (git short SHA by default) and renders the manifests in [k8s/](k8s/) into `artifacts/k8s/` with those exact image references:

```sh
./build-images.sh --save                                   # artifacts/*.tar.gz to upload
./build-images.sh --registry ghcr.io/me --push             # or push to a registry
./build-images.sh --version 1.2.0 --platform linux/amd64   # pin tag / target CPU
```

With `--save`, upload the `.tar.gz` files and load them on the target (`gunzip -c <file>.tar.gz | docker load`). Then start the pods with `kubectl apply -f artifacts/k8s/`. The backend Service is internal (`ClusterIP`), and the frontend Service is a `LoadBalancer` on port 80 that proxies to it. Keep the backend at 1 replica while it uses in-memory H2.

Both images run as a non-root user. The backend uses an in-memory H2 database, so data resets whenever its container restarts.

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
