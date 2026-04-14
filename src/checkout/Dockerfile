# ---------- Build Stage ----------
FROM node:22-alpine AS build-env

WORKDIR /usr/src/app

COPY --chown=node:node package.json yarn.lock ./

RUN yarn install --frozen-lockfile

COPY --chown=node:node . .

RUN yarn build

USER node

# ------------------Runtime Stage ----------------
FROM node:22-alpine

WORKDIR /app

# Alpine images already have a 'node' user with UID 1000
USER node

COPY --chown=node:node --from=build-env /usr/src/app/node_modules ./node_modules
COPY --chown=node:node --from=build-env /usr/src/app/dist ./dist

ENTRYPOINT ["node", "dist/main.js"]