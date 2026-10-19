# syntax=docker/dockerfile:1

# Stage 1: minify the HTML/CSS
FROM node:22-alpine AS build
WORKDIR /src
RUN npm install -g html-minifier-terser@7.2.0
COPY site/ ./site/
RUN mkdir -p /out && html-minifier-terser \
    --collapse-whitespace --remove-comments \
    --minify-css true --minify-js true \
    -o /out/index.html site/index.html

# Stage 2: serve with unprivileged Nginx (non-root, port 8080).
# "stable-alpine" keeps the base image patched; Trivy in CI gates every build.
FROM nginxinc/nginx-unprivileged:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /out/ /usr/share/nginx/html/
EXPOSE 8080
