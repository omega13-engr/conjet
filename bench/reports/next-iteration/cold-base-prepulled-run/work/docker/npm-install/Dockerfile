# syntax=docker/dockerfile:1.7
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
ARG CONJET_BENCH_ITERATION=0
RUN --mount=type=cache,target=/root/.npm \
    echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
    && export NPM_CONFIG_AUDIT='false' && export NPM_CONFIG_CACHE='/app/.npm-cache' && export NPM_CONFIG_FUND='false' && export NPM_CONFIG_PROGRESS='false' && export NPM_CONFIG_UPDATE_NOTIFIER='false' && mkdir -p '/app/.npm-cache' && npm install --prefer-offline --no-audit --no-fund --progress=false --ignore-scripts \
    && node -e "const _ = require('lodash'); console.log(_.camelCase('conjet npm install benchmark'))"