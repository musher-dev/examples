# Pinned by digest, not by tag. Musher rejects floating tags (:latest, :main,
# :edge) when you publish a Component, and the same discipline is worth applying
# to your base image: it is the difference between a rebuild that reproduces and
# a rebuild that surprises you.
FROM python:3.13-slim@sha256:bf503bb2243c5aad0aa951544dd60d165f992646441d35dea90893703fc26251

# Run as a non-root user. Musher does not require it, but a container that never
# needed root is one less thing to reason about.
RUN useradd --create-home --uid 10001 app
USER app
WORKDIR /home/app

COPY --chown=app:app src/ ./src/

# The port here is a default. The Component spec is what actually tells the
# platform which port to route to — see musher/component.yaml.
ENV PORT=8080
EXPOSE 8080

CMD ["python", "-u", "src/app.py"]
