```
cat README.md
# Log Catcher

Infraestructura de agregacion y visualizacion de logs para servicios Node.js usando **Loki + Promtail + Grafana**.

## Stack

| Componente | Tecnologia | Puerto |
|---|---|---|
| Log storage | Loki | `3100` |
| Log collector | Promtail | `9080` (interno) |
| Visualizacion / Alertas | Grafana | `3000` |

## Arquitectura

```
Servicios externos (Pino JSON -> stdout / archivo PM2) ---> Promtail ---> Loki ---> Grafana
                                                              ^               ^         ^
                                                       Docker SD       almacenamiento  dashboards
                                                    + static files                     + alertas
```

Log Catcher es un stack autónomo. No construye ni ejecuta los servicios que monitorea; solo recolecta sus logs.

Promtail soporta dos modos de descubrimiento simultaneos:

| Modo | Fuente | Mecanismo |
|---|---|---|
| Docker SD | Contenedores con label `log-catcher.enabled=true` | Docker socket |
| Static files | Archivos en `/var/log/services/*.log` | Volume mount al host |

## Requisitos

- Docker 24+
- Docker Compose v2

## Levantar el proyecto

```bash
docker compose up -d
```

Una vez corriendo:

- **Grafana**: http://localhost:3000 (anonymous access, login automatico)
- **Dashboard**: http://localhost:3000/d/log-catcher (pre-cargado automaticamente)

## Conectar servicios externos

### Opcion A: Servicios en Docker

Cada servicio que quiera ser monitoreado debe cumplir dos condiciones:

1. **Label de Docker** `log-catcher.enabled=true` en el contenedor
2. **Pino logger** emitiendo JSON a stdout con los campos `service`, `instance`, `level`

**docker-compose.yml del servicio:**

```yaml
services:
  recetar-api:
    build: .
    container_name: recetar-api
    labels:
      log-catcher.enabled: "true"
    environment:
      - SERVICE_NAME=recetar-api
      - INSTANCE_ID=1
      - LOG_LEVEL=info
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
```

**server.ts del servicio (ejemplo con Pino):**

```ts
import pino from 'pino';
import pinoHttp from 'pino-http';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: {
    service: process.env.SERVICE_NAME || 'unknown',
    instance: process.env.INSTANCE_ID || '0',
    host: process.env.HOSTNAME || 'unknown',
  },
});

app.use(pinoHttp({ logger }));
```

> Con esta config, Promtail descubre automaticamente el contenedor via Docker SD y scrapea sus logs desde stdout.

### Opcion B: Servicios con PM2

Cuando los servicios corren con PM2 en el host (sin Docker), Promtail lee logs desde archivos.

1. **En los servicios**: configurar Pino con los mismos campos (`service`, `instance`, `level`) y redirigir logs a `/var/log/services/`

```bash
# Configurar PM2 para escribir en el path compartido
pm2 start server.js --name recetar-api \
  --log /var/log/services/recetar-api.log \
  --merge-logs
```

2. **En log-catcher**: descomentar el volumen en `docker-compose.yml`:

```yaml
# En el servicio promtail:
volumes:
  ...
  - /var/log/services:/var/log/services:ro   # descomentar esta linea
```

3. **Reiniciar** log-catcher: `docker compose up -d`

> Los archivos deben ser JSON Lines (una linea = un objeto JSON, el formato nativo de Pino en modo production).

### Opcion mixta (Docker + PM2)

Ambos modos pueden coexistir. Promtail scrapea contenedores con label y archivos estaticos al mismo tiempo.

## Verificar conexion

1. Levantar log-catcher y los servicios externos
2. Abrir Grafana: http://localhost:3000
3. Usar Explore con la query `{service="recetar-api"}` o `{service="andes-api"}`
4. Si aparecen logs, la conexion funciona

## Estructura de logs (Pino)

Cada linea de log emitida por los servicios debe ser un objeto JSON con esta estructura:

```json
{
  "level": "info",
  "time": 1718234567890,
  "pid": 1,
  "hostname": "recetar-api-1",
  "name": "recetar-api",
  "service": "recetar-api",
  "instance": "1",
  "host": "recetar-api-1",
  "msg": "Fetched 42 prescriptions",
  "action": "list_prescriptions",
  "count": 42
}
```

Los campos `service`, `instance`, `level`, `module` y `source` son promovidos a labels de Loki.

## Panel de Uptime

El dashboard incluye un panel **"Time Since Last Log"** que muestra hace cuantos segundos cada servicio emitio su ultimo log:

- < 60s: verde (activo)
- 60s - 300s: amarillo (posible degradacion)
- > 300s: rojo (probable caida)

## Alertas

Log Catcher incluye 4 alertas provisionadas que se disparan cuando un servicio no emite logs durante 5 minutos:

| Alerta | Servicio |
|---|---|
| NoLogsRecetarApi | recetar-api |
| NoLogsRecetarApp | recetar-app |
| NoLogsAndesApi | andes-api |
| NoLogsAndesApp | andes-app |

Para recibir notificaciones, configurar un **contact point** en Grafana (Alerting > Contact points). Soportan email, Slack, Telegram, Webhook, etc.

## Consultas utiles en Grafana (LogQL)

```logql
# Todos los logs de un servicio
{service="recetar-api"}

# Solo errores
{service=~"recetar-api|andes-api", level="error"}

# Logs de una instancia especifica
{instance="2", service="recetar-api"}

# Conteo de errores por minuto
sum(count_over_time({level="error"}[1m])) by (service)

# Servicios sin logs en los ultimos 5 minutos (posible caida)
count_over_time({service="recetar-api"}[5m]) == 0

# Tiempo desde el ultimo log (uptime)
time() - max_over_time(timestamp({service=~"recetar-api|andes-api"}) [1h:]) by (service)
```

## Estructura del proyecto

```
log-catcher/
├── docker-compose.yml
├── config/
│   ├── loki-config.yaml
│   └── promtail-config.yml
├── grafana/
│   └── provisioning/
│       ├── datasources/loki.yml
│       ├── alerting/rules.yml
│       └── dashboards/
│           ├── provider.yml
│           └── logs-dashboard.json
├── services/                   # APIs de ejemplo (no parte del stack)
│   ├── recetar-api/
│   │   ├── package.json
│   │   ├── Dockerfile
│   │   └── src/server.js       # Express + Pino + pino-http + trafico simulado
│   └── andes-api/
│       ├── package.json
│       ├── Dockerfile
│       └── src/server.js       # Express + Pino + pino-http + trafico simulado
└── README.md
```
```