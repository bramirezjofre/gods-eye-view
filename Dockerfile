# syntax=docker/dockerfile:1.7
# God's Eye View — Dockerfile
#
# Two stages:
#   1. build   — installs ALL deps (production + dev), runs `vite build`
#                to produce dist/. devDeps are only needed for build.
#   2. runtime — installs ONLY production deps + the bundled vite +
#                vite-plugin-cesium + sharp + ws that we moved from
#                devDependencies to dependencies in this fork's
#                package.json (the upstream has them as devDeps but
#                `vite preview` needs them at runtime).
#
# Why not a static-server (nginx, caddy) only? Because the upstream
# app is NOT a static SPA — vite.config.js registers ~20 server-side
# proxies (OpenSky OAuth2, Overpass multi-mirror, AISStream WebSocket,
# TomTom, NASA FIRMS, Re:Earth, CCTV, GBFS, Radio Browser, Open-Meteo,
# GDELT, regional-brief, weather-effects, adsb.lol, OpenAI Realtime
# voice, etc.) via configurePreviewServer(). Those proxies resolve
# CORS, handle auth, rate-limit, cache, and forward to upstream APIs.
# Without them, most of the app's layers are empty. `vite preview`
# runs all of that in-process; the alternative (custom Express) would
# mean forking the upstream architecture.
#
# Engine note: package.json requires "node >=24.14.0 <25 || >=26 <27".
# node:24-alpine is on the 24.x line and is accepted.
#
# Final image size: ~700 MB. Cesium engine bundle + sharp + @mapbox
# tile decoders are the bulk. node_modules/cesium is ~150 MB, of
# which ~140 MB is Build/Source/Apps/Specs/scripts that vite-plugin-cesium
# copies into dist/cesium/ at build time and never touches again at
# runtime — those get trimmed in this Dockerfile.

# ------------------------------------------------------------------ build
FROM node:24-alpine AS build
WORKDIR /app

# Pinned lockfile copy first so npm ci is reproducible. The cache mount
# persists the npm download cache between builds (root-owned, so only
# available to subsequent builds, not to the running container).
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# Project source.
COPY . .

# Build-time public keys (Cesium ion, Google Maps). Build-arg lets the
# operator pass them at image build time; if not passed, the bundle
# is built without keys and the relevant layers degrade gracefully
# (Cesium falls back to OpenStreetMap, Google Maps features are empty).
ARG VITE_CESIUM_ION_TOKEN=""
ARG VITE_GOOGLE_MAPS_API_KEY=""
ENV VITE_CESIUM_ION_TOKEN=${VITE_CESIUM_ION_TOKEN}
ENV VITE_GOOGLE_MAPS_API_KEY=${VITE_GOOGLE_MAPS_API_KEY}

RUN npm run build

# ------------------------------------------------------------------ runtime
FROM node:24-alpine AS runtime
WORKDIR /app

# Production-only deps. The fork's package.json has `vite`,
# `vite-plugin-cesium`, `sharp`, `ws` as dependencies (the upstream
# has them as devDeps, but we need them at runtime to run
# `vite preview`). The only thing left in devDependencies is
# `puppeteer`, which gets dropped here.
#
# Combine this with the cesium trim in the SAME RUN so the deleted
# files don't leak into the runtime layer (Docker layers are
# immutable — a separate `RUN rm` would leave the bytes in the COPY
# layer, only shadowing them with a smaller delta layer on top).
#
# Trim rationale: cesium's `Build/`, `Source/`, `Apps/`, `Specs/` and
# `scripts/` directories are only referenced at *build* time by
# vite-plugin-cesium (it copies them into dist/cesium/). At runtime,
# /app/dist/cesium/Cesium.js is what gets served to the browser —
# node_modules/cesium/* is dead weight (~150 MB).
COPY --from=build --chown=1000:1000 /app/package.json     /app/package.json
COPY --from=build --chown=1000:1000 /app/package-lock.json /app/package-lock.json
COPY --from=build --chown=1000:1000 /app/node_modules      /app/node_modules
COPY --from=build --chown=1000:1000 /app/dist              /app/dist
COPY --from=build --chown=1000:1000 /app/vite.config.js   /app/vite.config.js
COPY --from=build --chown=1000:1000 /app/src               /app/src

RUN npm prune --omit=dev --no-audit --no-fund \
 && rm -rf /app/node_modules/cesium/Build \
           /app/node_modules/cesium/Source \
           /app/node_modules/cesium/Apps \
           /app/node_modules/cesium/Specs \
           /app/node_modules/cesium/scripts \
 && rm -f  /app/node_modules/cesium/CHANGES.md \
           /app/node_modules/cesium/index.cjs \
           /app/node_modules/cesium/eslint.config.js \
           /app/node_modules/cesium/lint-staged.config.js \
           /app/node_modules/cesium/sgconfig.yml \
           /app/node_modules/cesium/tsconfig.json \
 && mkdir -p /app/.gev-cache/overpass \
 && chown -R 1000:1000 /app/node_modules /app/.gev-cache

# Drop privileges. alpine's bundled `node` user is uid:gid 1000:1000.
# The COPYs above already chowned the files to that uid; using the
# numeric id (rather than the symbolic name) avoids a build error if
# the runtime stage image lacks a symbolic "node" entry in /etc/passwd
# at multi-stage build time.
USER 1000:1000

ENV NODE_ENV=production
ENV PORT=5173
ENV HOST=0.0.0.0

EXPOSE 5173

# Healthcheck hits /, the SPA index. We deliberately avoid /api/*
# proxies — they're rate-limited by their upstream providers
# (OpenSky, Overpass, etc.) and a 30-second healthcheck loop would
# burn quota. /'s response is served by vite preview itself; a 200
# means the node process is alive and the proxy middleware is
# mounted (vite would crash on startup if configurePreviewServer()
# threw).
#
# --start-period=10s gives vite preview ~10s to boot before the
# first failure counts toward --retries=3. The first health probe
# lands ~30s after container start, but the start-period covers the
# 1-3s vite needs plus any incidental startup I/O.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:5173/ >/dev/null || exit 1

CMD ["node_modules/.bin/vite", "preview", "--host", "0.0.0.0", "--port", "5173"]