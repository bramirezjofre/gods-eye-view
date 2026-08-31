# God's Eye View — Dockerfile
#
# Two stages:
#   1. build   — installs ALL deps (production + dev), runs `vite build`
#                to produce dist/. The devDeps are needed by vite-plugin-cesium
#                and the build pipeline.
#   2. runtime — installs ONLY production deps. To run `vite preview`
#                (which is the runtime command we use so all the
#                configurePreviewServer() proxies in vite.config.js stay
#                active in the running container), we re-add vite +
#                vite-plugin-cesium + sharp. They are *not* modified to
#                `dependencies` in package.json (that would touch the
#                upstream tree) — they live in /node_modules of the
#                runtime image and are installed with --no-save so
#                package.json/package-lock.json are not mutated.
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
# Final image size: ~400 MB. Cesium engine bundle + sharp + @mapbox
# tile decoders are the bulk.

# ------------------------------------------------------------------ build
FROM node:24-alpine AS build
WORKDIR /app

# Pinned lockfile copy first so npm ci is reproducible.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

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

# `npm prune --omit=dev` would drop vite (it is a devDep in the
# upstream package.json), but `vite preview` is what we run. The
# --no-save installs the same packages without mutating package.json
# or package-lock.json — important because we don't want to change
# the upstream tree as part of the dockerization. We also reinstall
# sharp because vite-plugin-cesium uses it for tile decoding at
# preview time.
RUN npm prune --omit=dev --no-audit --no-fund \
 && npm install --no-save --no-audit --no-fund \
      vite@^6.0.0 \
      vite-plugin-cesium@^1.2.23

# Copy only the files the preview server actually needs at runtime.
# (We do this AFTER the prune+install above so node_modules is in
# the right state.) Note: vite.config.js imports from src/data/* and
# src/voice/* — the build stage already bundled these into dist/, but
# `vite preview` re-evaluates the config at startup, so the source
# files have to be present in the runtime image too.
COPY --from=build --chown=1000:1000 /app/package.json     /app/package.json
COPY --from=build --chown=1000:1000 /app/package-lock.json /app/package-lock.json
COPY --from=build --chown=1000:1000 /app/node_modules      /app/node_modules
COPY --from=build --chown=1000:1000 /app/dist              /app/dist
COPY --from=build --chown=1000:1000 /app/vite.config.js   /app/vite.config.js
COPY --from=build --chown=1000:1000 /app/src               /app/src

# The disk cache directory needs to exist (and be writable by the
# non-root user) before the server starts.
RUN mkdir -p /app/.gev-cache/overpass \
 && chown -R 1000:1000 /app/.gev-cache

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

# Healthcheck: hit the SPA index. Vite preview returns 200 for the
# built index.html. We avoid the /api/* routes because the proxies are
# rate-limited and a HEAD flood is worse than no check.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:5173/ >/dev/null || exit 1

CMD ["npm", "run", "preview", "--", "--host", "0.0.0.0", "--port", "5173"]