# syntax=docker/dockerfile:1.7
FROM node:22-alpine
RUN corepack enable
WORKDIR /app
COPY . .
ARG NEXT_PUBLIC_API_URL=http://localhost:4000/api/v1
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
RUN --mount=type=cache,id=ela-pnpm-store,target=/pnpm/store,sharing=locked \
  pnpm config set store-dir /pnpm/store \
  && pnpm config set fetch-retries 8 \
  && pnpm config set fetch-retry-mintimeout 10000 \
  && pnpm config set fetch-retry-maxtimeout 120000 \
  && pnpm config set fetch-timeout 600000 \
  && pnpm config set network-concurrency 4 \
  && pnpm install --frozen-lockfile --prefer-offline \
  && pnpm --filter @ela/design-system build \
  && pnpm --filter @ela/web build
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=12 CMD node -e "fetch('http://127.0.0.1:3000/__ela/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["pnpm", "--filter", "@ela/web", "start"]
