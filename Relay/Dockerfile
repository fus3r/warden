FROM node:24-alpine
WORKDIR /app/Relay
COPY Relay/package.json Relay/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY Relay/server.mjs ./
COPY Relay/public ./public
COPY Resources/Phone /app/Resources/Phone
RUN mkdir /data && chown node:node /data
USER node
ENV BIND_ADDRESS=0.0.0.0 PORT=8787 DATA_DIR=/data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "fetch('http://127.0.0.1:8787/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.mjs"]
