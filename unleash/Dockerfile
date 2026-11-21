FROM unleashorg/unleash-server:7
USER node
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -q --spider http://localhost:4242/health || exit 1

EXPOSE 4242