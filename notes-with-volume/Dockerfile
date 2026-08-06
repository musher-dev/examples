# Pinned by digest. Resolve a current one with:
#   docker buildx imagetools inspect python:3.13-slim | grep '^Digest:'
FROM python:3.13-slim@sha256:bf503bb2243c5aad0aa951544dd60d165f992646441d35dea90893703fc26251

RUN useradd --create-home --uid 10001 app

# The Volume mounts at /data. Create it with the right ownership at build time:
# Musher mounts an empty volume on first deploy, and a container running as a
# non-root user cannot chown a mount point it does not already own.
RUN mkdir -p /data && chown app:app /data

USER app
WORKDIR /home/app

COPY --chown=app:app src/ ./src/

ENV PORT=8080 \
    DATA_DIR=/data
EXPOSE 8080

# Declaring the mount point documents intent for anyone running this outside
# Musher. The Component spec is what actually provisions the Volume.
VOLUME ["/data"]

CMD ["python", "-u", "src/app.py"]
