# syntax=docker/dockerfile:1.7
FROM node:22-alpine
RUN corepack enable
WORKDIR /app
COPY . .
RUN --mount=type=cache,id=ela-pnpm-store,target=/pnpm/store,sharing=locked \
  pnpm config set store-dir /pnpm/store \
  && pnpm config set fetch-retries 8 \
  && pnpm config set fetch-retry-mintimeout 10000 \
  && pnpm config set fetch-retry-maxtimeout 120000 \
  && pnpm config set fetch-timeout 600000 \
  && pnpm config set network-concurrency 4 \
  && pnpm install --frozen-lockfile --prefer-offline \
  && pnpm --filter @ela/queue build \
  && pnpm --filter @ela/worker build
CMD ["node", "apps/worker/dist/main.js"]
