# syntax=docker/dockerfile:1.7
FROM conjet-bench-node-pnpm:9.15.9
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
ARG CONJET_BENCH_ITERATION=0
RUN --mount=type=cache,target=/root/.npm \
    echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
    && export COREPACK_HOME='/app/.corepack-cache' && export NPM_CONFIG_AUDIT='false' && export NPM_CONFIG_CACHE='/app/.npm-cache' && export NPM_CONFIG_FUND='false' && export NPM_CONFIG_PROGRESS='false' && export NPM_CONFIG_STORE_DIR='/app/.pnpm-store' && export NPM_CONFIG_UPDATE_NOTIFIER='false' && export PNPM_HOME='/app/.pnpm-state' && mkdir -p '/app/.corepack-cache' && mkdir -p '/app/.npm-cache' && mkdir -p '/app/.pnpm-state' && mkdir -p '/app/.pnpm-store' && (command -v pnpm >/dev/null 2>&1 || (corepack enable >/dev/null 2>&1 && corepack prepare pnpm@9.15.9 --activate >/dev/null 2>&1 || npm install -g pnpm@9.15.9 >/dev/null)) && pnpm install --frozen-lockfile --prefer-offline --ignore-scripts \
    && node -e "const _ = require('lodash'); console.log(_.camelCase('conjet pnpm install benchmark'))"