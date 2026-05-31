FROM node:22-alpine
ENV COREPACK_ENABLE_PROJECT_SPEC=0
RUN corepack disable >/dev/null 2>&1 || true \
    && npm install -g pnpm@9.15.9 >/dev/null \
    && pnpm --version >/dev/null