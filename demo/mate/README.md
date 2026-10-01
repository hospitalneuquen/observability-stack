# Mate — app de smoke-test con OTel SDK + Pino (temática argentina).

El primer `docker compose --profile mate build` puede tardar varios minutos (`npm install` del árbol de OTel). Después usa cache de capas.

```bash
docker compose --profile mate up -d --build
curl 'http://localhost:4000/cebada?gusto=amargo'
./scripts/validate.sh
```

| Endpoint | Qué hace |
|---|---|
| `GET /health` | Healthcheck |
| `GET /cebada?gusto=amargo\|dulce\|terere\|con-yuyos` | Ceba un mate (~20% se vuelca → 500) |
| `GET /quilombo` | Error a propósito |
