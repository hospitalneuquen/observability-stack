FROM node:22-alpine

WORKDIR /app

# Prefer lockfile when present; npm can take several minutes on first build (OTel tree).
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-fund --no-audit

COPY src ./src

ENV PORT=4000
EXPOSE 4000
CMD ["npm", "start"]
