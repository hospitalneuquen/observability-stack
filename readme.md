# Observabilidad Andes (v2)

Stack de agregación y visualización **OpenTelemetry-ready** para servicios Andes (Node.js) usando **Grafana Alloy + Loki + Tempo + Prometheus + Grafana** (LGTM).

Diseño y decisiones detalladas: [PLAN.md](./PLAN.md).

**Demo runnable (Compose + nginx):** [demo/README.md](./demo/README.md)

```bash
cd demo && cp .env.example .env && docker compose up -d
# Grafana → http://localhost:8080/
```

## Stack

| Componente | Tecnología | Puerto |
|---|---|---|
| Collector / hub | Grafana Alloy | OTLP `4317` (gRPC), `4318` (HTTP) |
| Log storage | Loki | `3100` |
| Trace storage | Tempo | `3200` |
| Metrics | Prometheus | `9090` |
| UI / alertas | Grafana | `3000` |

> Promtail fue deprecado. Alloy lo reemplaza y además recibe OTLP.

## Arquitectura

```
Apps (Pino JSON → stdout)  ──tail──┐
Apps (OTLP traces/metrics[/logs]) ──┼──► Alloy ──► Loki / Tempo / Prometheus ──► Grafana
@andes/log (dominio/auditoría) ────────► Mongo (fuera de este stack)
```

Este repo **no** construye ni ejecuta las apps monitoreadas; solo recolecta y visualiza telemetría.

Alloy combina:

| Modo | Fuente | Uso |
|---|---|---|
| Docker SD | Contenedores con label `obs.enabled=true` | Tail de stdout |
| OTLP | Apps que exportan al collector | Traces, metrics, (opcional) logs |

## Requisitos

- Docker 24+
- Docker Compose v2

## Entornos

Mismo compose, distinto overlay / `.env`:

| Entorno | Dónde | Cómo |
|---|---|---|
| **local** | laptop | `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d` |
| **test** | VM Ubuntu | `... -f docker-compose.test.yml` + `.env.test` |
| **prod** | VM Ubuntu | `... -f docker-compose.prod.yml` + `.env.prod` |

Una vez corriendo (local):

- **Grafana**: http://localhost:3000
- **OTLP HTTP** (desde otras apps en la misma red): `http://alloy:4318`
- **OTLP desde el host**: `http://localhost:4318`

Variable típica en las apps:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318
# o desde el host:
# OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

## Conectar servicios (Docker)

1. Label `obs.enabled=true` en el contenedor
2. Logger operacional **Pino** emitiendo JSON a stdout (ver contrato abajo)
3. (Fase 2) Export OTLP al Alloy

```yaml
services:
  andes-api:
    build: .
    container_name: andes-api
    labels:
      obs.enabled: "true"
    environment:
      - SERVICE_NAME=andes-api
      - INSTANCE_ID=1
      - DEPLOYMENT_ENVIRONMENT=local
      - LOG_LEVEL=info
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped
```

Docker SD y OTLP pueden usarse a la vez.

## Contrato de logs (Pino / JSON Lines)

Cada línea = un objeto JSON.

**Labels Loki** (baja cardinalidad — solo estos):

| Label | Campo origen | Ejemplo |
|---|---|---|
| `service_name` | `service.name` | `andes-api` |
| `level` | `level` | `info` |
| `deployment_environment` | `deployment.environment` | `local` \| `test` \| `prod` |

**Campos en el cuerpo** (no labels):

- `module` — en el monolito Andes: `rup`, `turnos`, `mpi`, …
- `service.instance.id`, `action`, `msg`, errores, request ids
- `trace_id`, `span_id` — correlación con Tempo

`module` **no** se promueve a label: se filtra con LogQL (`| json | module="rup"`). Evita explotar streams de Loki.

Ejemplo:

```json
{
  "level": "info",
  "time": 1718234567890,
  "service.name": "andes-api",
  "service.instance.id": "andes-api-1",
  "deployment.environment": "test",
  "module": "rup",
  "msg": "prestacion guardada",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7"
}
```

### Andes: dos canales de log

| Canal | Herramienta | Destino | Uso |
|---|---|---|---|
| Operacional | Pino + pino-http | stdout → Alloy → Loki | HTTP, errores runtime, jobs |
| Dominio / auditoría | `@andes/log` | Mongo | Eventos de negocio (no migrar a Loki) |

Ejemplo mínimo Pino:

```ts
import pino from 'pino';
import pinoHttp from 'pino-http';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: {
    'service.name': process.env.SERVICE_NAME || 'andes-api',
    'service.instance.id': process.env.INSTANCE_ID || '0',
    'deployment.environment': process.env.DEPLOYMENT_ENVIRONMENT || 'local',
  },
});

const rupLog = logger.child({ module: 'rup' });
app.use(pinoHttp({ logger }));
```

## Verificar conexión

1. Levantar este stack y el servicio
2. Grafana → Explore (Loki): `{service_name="andes-api"}`
3. Filtrar módulo: `{service_name="andes-api"} | json | module="rup"`
4. Solo errores: `{service_name="andes-api", level="error"}`
5. (Fase 2) Explore Tempo / link logs ↔ traces por `trace_id`

## Consultas útiles (LogQL)

```logql
# Todo un servicio
{service_name="andes-api"}

# Errores de varios servicios
{service_name=~"andes-api|recetar-api", level="error"}

# Por módulo (campo JSON, no label)
{service_name="andes-api"} | json | module="turnos"

# Conteo de errores por minuto
sum(count_over_time({level="error"}[1m])) by (service_name)
```

## Health y alertas

- **Uptime real:** health HTTP + métricas Prometheus (RED), no “tiempo desde el último log”.
- El panel “time since last log” puede existir como señal auxiliar.
- Alertas genéricas por `service_name` / métricas; no una regla hardcodeada por cada app.
- Contact points en Grafana (Slack, email, webhook, …).

## Acceso y RBAC (Grafana OSS)

El control de acceso del stack gratuito vive en **Grafana**. Loki / Tempo / Prometheus OSS no ofrecen RBAC fino por label ni multi-tenant “por equipo” por sí solos.

### Qué incluye OSS

| Mecanismo | Para qué sirve |
|---|---|
| Roles de org **Viewer / Editor / Admin** | Permisos grueso de la organización |
| **Teams** + **Folders** | Quién ve o edita dashboards y alertas de cada área |
| Permisos de **datasource** | Quién puede query-ar Loki / Tempo / Prometheus (sí/no al datasource, no por `service_name`) |
| Auth local, LDAP/AD, OAuth/OIDC | Identidad; mapear grupos → roles y teams |
| **Orgs** separadas o stacks por entorno | Aislar p.ej. test vs prod |
| Service accounts | Tokens para API / provisioning |

### Qué no incluye OSS (Enterprise / Cloud)

- Roles custom / permisos granulares (RBAC full)
- **LBAC** (filtrar Loki/Prometheus por labels, ej. solo `service_name=andes-api`)
- Aislamiento real de líneas de log/métricas dentro del mismo datasource

Quien tenga acceso al datasource Loki y a Explore puede LogQL-ear **todo** lo que haya en ese Loki.

### Política por entorno

| Entorno | Acceso |
|---|---|
| **local** | Grafana anonymous / sin auth (laptop) |
| **test** | Auth obligatoria; SSO o usuarios locales; teams + folders |
| **prod** | Auth + SSO preferido; sin anonymous; folders/teams; Explore solo ops |

### Perfiles sugeridos

| Perfil | Rol / alcance |
|---|---|
| Ops / platform | Admin o Editor; Explore; todos los datasources |
| Devs de un servicio | Team del servicio; Viewer (o Editor solo de su folder); Explore preferible solo en test |
| Negocio / clínico | En general **fuera** de Grafana; si hace falta, solo dashboards acotados en un folder Viewer |

### Patrones recomendados (sin licencia paga)

1. Folders por equipo/servicio + permisos View/Edit por Team.
2. Separar **test** y **prod** (org distinta o stack distinto): es el aislamiento de datos más barato y efectivo.
3. No dar Explore a perfiles no-ops en prod.
4. Mapear grupos del IdP → Teams Grafana.
5. No mezclar logs de prod en el mismo Loki que ven todos los entornos.

## Estructura del proyecto (target)

```
observabilidad/
├── PLAN.md
├── readme.md
├── docker-compose.yml
├── docker-compose.local.yml
├── docker-compose.test.yml
├── docker-compose.prod.yml
├── config/
│   ├── alloy/
│   ├── loki.yml
│   ├── tempo.yml
│   └── prometheus.yml
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       ├── alerting/
│       └── dashboards/
└── .env.example
```

## Roadmap corto

1. Compose LGTM + Alloy (local / test / prod)
2. Contrato de logs + datasources Grafana
3. Pino operacional en andes-api + label `obs.enabled`
4. OTel SDK (traces) → Alloy → Tempo; correlación en Grafana
5. Métricas RED + alertas

## Fuera de scope (v2 inicial)

- Migrar `@andes/log` / Mongo a Loki
- Mimir / clustering Loki
- Apagar Elastic APM el día 1 (convive hasta que Tempo cubra lo necesario)
- LBAC / RBAC granular Enterprise (usamos Teams + Folders + separación por entorno)
