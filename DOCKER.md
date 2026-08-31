# gods-eye-view (dockerizado)

Fork de [bilawalsidhu/gods-eye-view](https://github.com/bilawalsidhu/gods-eye-view) con un `Dockerfile` + `docker-compose.yml` que permite correr la app entera en un container.

## Por qué la dockerización no es trivial

Este proyecto **no es un sitio estático**. `vite.config.js` registra **~20 proxies server-side** que:

- Resuelven **CORS** (la mayoría de las APIs no lo tienen habilitado para browsers).
- Manejan **OAuth2 / API keys / tokens** (OpenSky, TomTom, FIRMS, AISStream, OpenAI Realtime).
- Hacen **rate-limit** contra espejos públicos (Overpass multi-mirror, GBFS).
- **Cachean** en disco respuestas grandes (Overpass disk cache 7-30 días, AISStream state).
- Sirven **WebSockets** (AISStream live vessels, OpenAI Realtime voice).

Si solo hicieras `vite build` y sirvieras el `dist/`, la app **no arrancaría** — el 80% de las features dependen de estos proxies.

La solución es ejecutar `vite preview` dentro del container, que respeta el mismo bloque `configurePreviewServer()` que `vite dev`. **Cero cambios al código fuente del upstream.**

## Cómo correrlo

```bash
cp .env.example .env  # opcional, solo si tenés keys
docker compose up -d --build
open http://127.0.0.1:5173
```

## Lo que tenés que saber

- **Imagen**: `gods-eye-view:latest`, ~1.14 GB (Cesium engine bundle + sharp + @mapbox tile decoders dominan).
- **Puerto**: 5173 (default de Vite).
- **Bind**: `0.0.0.0:5173:5173` (escucha en todas las interfaces, accesible desde la LAN). Si querés restringir a solo localhost, cambiá a `127.0.0.1:5173:5173`. **No hay auth** — el upstream es un dashboard personal, no un servicio público. Si lo exponés a internet, pasalo por Nginx Proxy Manager con auth.
- **Cache de proxies** (`./data/.gev-cache/`): sobrevive recreaciones. No la borres a menos que sepas lo que hacés — el siguiente boot re-quemaría cuota pública de Overpass y OpenSky.
- **API keys opcionales**: sin keys la app arranca igual, pero las capas afectadas quedan vacías. La 3D globe funciona con OpenStreetMap como fallback sin token de Cesium ion.

## Arquitectura

```
Browser (SPA estática)
   ↓
docker container (vite preview on :5173)
   ├─ serve dist/index.html y assets
   └─ /api/* middleware: 20 proxies a APIs upstream
        ├─ OpenSky OAuth2 + cache adaptativo
        ├─ Overpass (4 mirrors con fail-over + disk cache 7-30d)
        ├─ AISStream WebSocket proxy
        ├─ TomTom traffic flow (rate-limited)
        ├─ NASA FIRMS active fires
        ├─ Re:Earth terrain heights
        ├─ OpenAI Realtime voice
        ├─ CCTV (Austin, Caltrans, TfL)
        ├─ Radio Browser
        ├─ Open-Meteo weather
        └─ ... 10 más
```

## Limitaciones conocidas

- **GPU rendering**: Cesium hace WebGL pesado. En el navegador funciona, en CI o headless requiere Puppeteer (incluido como devDep). En el container solo se sirve, no se renderiza.
- **First build es lento**: `npm ci` + `vite build` con sharp + cesium pesan. ~2-3 min la primera vez, después los layers de Docker cachean.
- **Memoria**: el container de preview puede usar 200-400 MB en idle (Vite + sharp + el runtime de node). Si tu host tiene poca RAM, ajustá los límites en compose.

## Estructura añadida al fork

```
.
├── Dockerfile              # multi-stage build, node:24-alpine
├── docker-compose.yml      # single-service, env vars con defaults seguros
├── .dockerignore           # excluye node_modules, dist, .git
├── .env.example            # template de keys opcionales
└── DOCKER.md               # este archivo
```

Todo lo demás es el upstream sin tocar.
