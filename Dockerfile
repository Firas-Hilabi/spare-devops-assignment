# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies ----
# Isolated so build tools/dev deps never reach the final image.
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# npm ci = reproducible install from the lockfile (fails if it drifts).
RUN npm ci --omit=dev

# ---- Stage 2: minimal runtime image ----
FROM node:20-alpine AS runtime

# tini = lightweight init for proper PID 1 signal handling / zombie reaping.
RUN apk add --no-cache tini

ENV NODE_ENV=production
WORKDIR /app

# Copy vetted deps and app source, owned by the unprivileged 'node' user.
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

# Drop root: run as the built-in non-root 'node' user.
USER node

EXPOSE 8080

# Container-level liveness: hits the app's DB-backed /health endpoint.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
