FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public 2>/dev/null || true
COPY --from=builder /app/package*.json ./
RUN npm ci --omit=dev

EXPOSE 3011
CMD ["sh", "-c", "node_modules/.bin/next start -p ${PORT:-3011}"]
