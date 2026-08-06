# Pinned by digest, not by tag — same discipline as every other example here.
FROM python:3.13-slim@sha256:bf503bb2243c5aad0aa951544dd60d165f992646441d35dea90893703fc26251

RUN useradd --create-home --uid 10001 app
USER app
WORKDIR /home/app

COPY --chown=app:app src/ ./src/

# No pip install. The Redis conversation is forty lines of the standard
# library, and a dependency you do not add is a dependency you do not pin,
# scan, or upgrade.
ENV PORT=8080
EXPOSE 8080

CMD ["python", "-u", "src/app.py"]
