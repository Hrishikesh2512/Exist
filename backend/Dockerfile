FROM docker.io/library/node:22-bookworm-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx prisma generate && npx tsc -p tsconfig.build.json
ENV NODE_ENV=production
EXPOSE 8080
CMD ["sh", "-c", "npx prisma db push --skip-generate && exec node dist/src/server.js"]
