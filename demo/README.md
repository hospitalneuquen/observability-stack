# Demo stack — Alloy + Loki + Tempo + Prometheus + Grafana + nginx

Playground declarativo para que los devs prueben telemetría contra el stack de observabilidad Andes.

Diseño: [../PLAN.md](../PLAN.md) · contrato y RBAC: [../readme.md](../readme.md)

## Qué incluye

| Path (vía nginx) | Componente |
|---|---|
| `/` | Grafana |
| `/prometheus/` | Prometheus UI |
| `/loki/` | Loki API |
| `/tempo/` | Tempo API |
| `/alloy/` | Alloy UI |
| host `:4317` / `:4318` | OTLP gRPC / HTTP → Alloy (directo) |
| host `:4000` | App **mate** (profile `mate`) |

Todo se configura por YAML/Alloy + variables en `.env` (secretos).

## Arranque

```bash
cd demo
cp .env.example .env
# editar .env: passwords, PUBLIC_HOST=IP-de-la-VM

docker compose up -d
# + app mate (recomendado para validar el pipeline):
docker compose --profile mate up -d --build

./scripts/validate.sh
```

Grafana: `http://$PUBLIC_HOST:$PUBLIC_PORT/`  
Mate: `http://$PUBLIC_HOST:4000/cebada?gusto=amargo`  
Login: valores de `GF_SECURITY_ADMIN_*` en `.env`.

En una **VM compartida** conviene:

```env
GF_AUTH_ANONYMOUS_ENABLED=false
GF_SECURITY_ADMIN_PASSWORD=<fuerte>
NGINX_BASIC_AUTH_USER=observer
NGINX_BASIC_AUTH_PASSWORD=<fuerte>
PUBLIC_HOST=<ip-o-hostname>
```

En **laptop**, anonymous + sin basic auth está bien para jugar.

## Estructura

```
demo/
├── .env.example
├── docker-compose.yml
├── config/
│   ├── alloy/config.alloy
│   ├── loki/loki.yml
│   ├── tempo/tempo.yml
│   ├── prometheus/prometheus.yml
│   ├── nginx/nginx.conf
│   ├── nginx/entrypoint.sh
│   └── grafana/provisioning/
│       ├── datasources/datasources.yml
│       └── dashboards/
└── README.md
```

## Conectar una app (Docker)

1. Misma red Docker o OTLP al host:
   - red del stack: `OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318`
   - desde el host: `http://localhost:4318`
2. Label para scrapear logs: `obs.enabled=true`
3. Logs JSON (Pino) con `service.name`, `level`, `deployment.environment` (ver [../readme.md](../readme.md))

Ejemplo mínimo:

```yaml
services:
  mi-api:
    image: mi-api:dev
    labels:
      obs.enabled: "true"
    environment:
      SERVICE_NAME: mi-api
      DEPLOYMENT_ENVIRONMENT: local
      OTEL_EXPORTER_OTLP_ENDPOINT: http://host.docker.internal:4318
    # Si está en el mismo compose, usá http://alloy:4318 y:
    # external network → unir a observability-demo_obs
```

Unir un compose externo a la red del demo:

```bash
docker network ls | grep obs
# network: observability-demo_obs  (nombre puede variar)

# en el otro compose:
networks:
  obs:
    external: true
    name: observability-demo_obs
```

## Verificar

```bash
./scripts/validate.sh
```

Chequea: containers up, Grafana/nginx, Loki/Tempo/Prometheus ready, OTLP :4318, datasources, y (si corre mate) logs→Loki, métricas→Prometheus, traces→Tempo.

Manual:

1. Grafana → Dashboards → **Mate — observabilidad** (o `/d/obs-demo`)
2. Explore → Loki: `{service_name="mate"}`
3. Explore → Tempo: `{ resource.service.name="mate" }`
4. Explore → Prometheus: `mate_cebadas_total{service_name="mate"}`
5. `curl 'http://localhost:4000/cebada?gusto=dulce'`

## App mate

Generador tonto de las 3 señales (profile Compose `mate`) con **OTel SDK + Pino**, temática argentina (cebada / vuelco / quilombo). El primer `npm install` en el build puede tardar varios minutos.

| Señal | Cómo |
|---|---|
| Logs | Pino JSON a stdout + label `obs.enabled=true` |
| Traces | OTLP → Alloy → Tempo (auto-instrumentation HTTP) |
| Metrics | `mate.cebadas` / `mate.vuelcos` vía OTLP → Prometheus |

## Secretos

- Copiá `.env.example` → `.env` (gitignored).
- No commitear `.env`.
- Nginx genera el htpasswd al arrancar desde `NGINX_BASIC_AUTH_*`.

## Parar / reset

```bash
docker compose down
# borrar datos locales:
docker compose down -v
```
