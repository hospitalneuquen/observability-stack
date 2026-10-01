'use strict';

const express = require('express');
const pino = require('pino');
const pinoHttp = require('pino-http');
const { trace, metrics, context } = require('@opentelemetry/api');

const serviceName = process.env.SERVICE_NAME || 'mate';
const port = Number(process.env.PORT || 4000);

const GUSTOS = ['amargo', 'dulce', 'terere', 'con-yuyos'];

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: {
    'service.name': serviceName,
    'service.instance.id': process.env.INSTANCE_ID || '1',
    'deployment.environment': process.env.DEPLOYMENT_ENVIRONMENT || 'local',
  },
  mixin() {
    const span = trace.getSpan(context.active());
    if (!span) return {};
    const sc = span.spanContext();
    return { trace_id: sc.traceId, span_id: sc.spanId };
  },
});

const meter = metrics.getMeter('mate');
const cebadas = meter.createCounter('mate.cebadas', {
  description: 'Cuántos mates se cebaron',
});
const vuelcos = meter.createCounter('mate.vuelcos', {
  description: 'Veces que se volcó el mate (errores)',
});

const app = express();
const mateLog = logger.child({ module: 'cebador' });

app.use(
  pinoHttp({
    logger,
    customProps() {
      const span = trace.getSpan(context.active());
      if (!span) return {};
      const sc = span.spanContext();
      return { trace_id: sc.traceId, span_id: sc.spanId };
    },
  })
);

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: serviceName });
});

// Cebar un mate (happy path + ~20% se vuelca)
app.get('/cebada', (req, res) => {
  const gusto = String(req.query.gusto || 'amargo');
  cebadas.add(1, { gusto });

  const tracer = trace.getTracer('mate');
  tracer.startActiveSpan('cebar_mate', (span) => {
    span.setAttribute('mate.gusto', gusto);
    mateLog.info({ action: 'cebada', gusto }, `cebando un mate ${gusto}`);

    if (Math.random() < 0.2) {
      vuelcos.add(1, { gusto });
      span.setStatus({ code: 2, message: 'vuelco' });
      mateLog.error({ action: 'vuelco', gusto }, 'uy, se volcó el mate');
      span.end();
      return res.status(500).json({ ok: false, error: 'vuelco', gusto });
    }

    span.end();
    res.json({ ok: true, gusto, msg: 'buen mate, dale' });
  });
});

app.get('/quilombo', (_req, res) => {
  mateLog.warn({ action: 'quilombo' }, 'se armó quilombo');
  tiraErrorAProposito();
});

function tiraErrorAProposito() {
  throw new Error('el termo explotó');
}

app.use((err, _req, res, _next) => {
  vuelcos.add(1, { gusto: 'quilombo' });
  mateLog.error({ err: err.message, action: 'unhandled' }, 'se rompió todo');
  res.status(500).json({ ok: false, error: err.message });
});

app.listen(port, () => {
  mateLog.info({ action: 'listen', port }, 'mate listo para cebar');
});

const auto = process.env.BOBA_AUTO_TRAFFIC !== 'false' && process.env.MATE_AUTO_TRAFFIC !== 'false';
if (auto) {
  setInterval(() => {
    const gusto = GUSTOS[Math.floor(Math.random() * GUSTOS.length)];
    fetch(`http://127.0.0.1:${port}/cebada?gusto=${gusto}`).catch(() => {});
  }, Number(process.env.MATE_INTERVAL_MS || process.env.BOBA_INTERVAL_MS || 3000));
}
