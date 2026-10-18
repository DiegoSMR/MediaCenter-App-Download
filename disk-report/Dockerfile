FROM python:3.12-alpine
# Solo libreria estandar de Python: nada que instalar.
COPY server.py clean.py extras.py verify.py /app/
COPY static /app/static
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
ENTRYPOINT ["python3", "-u", "/app/server.py"]
