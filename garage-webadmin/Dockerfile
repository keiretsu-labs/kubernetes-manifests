FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
COPY overlay/src/auto-login.ts src/auto-login.ts
COPY overlay/src/pages/ src/pages/
RUN sed -i '/import "\.\/polyfills\.js"/a import ".\/auto-login.ts"' src/main.ts
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 80
