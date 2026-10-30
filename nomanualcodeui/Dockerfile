# syntax=docker/dockerfile:1

# ---- Build: bundle the React app with Vite ----
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ---- Runtime: Express serves dist/ and proxies /api/persons to the backend ----
FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./
COPY --from=build /app/dist dist

# The image's `node` user, by UID so Kubernetes `runAsNonRoot` can verify it.
USER 1000
EXPOSE 3000
# Where the backend lives, as seen from this container. Override at deploy time.
ENV PORT=3000 API_URL=http://localhost:8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD wget -qO- http://localhost:3000/api/health || exit 1

CMD ["node", "server.js"]
