# Pinned by digest, not by tag — same discipline as every other example here.
FROM python:3.13-slim@sha256:bf503bb2243c5aad0aa951544dd60d165f992646441d35dea90893703fc26251

RUN useradd --create-home --uid 10001 app
USER app
WORKDIR /home/app

COPY --chown=app:app src/ ./src/

# One image, two workloads. ROLE selects which one this container runs; the
# two Components in musher/ set it to `api` and `worker` respectively. The
# default here is what a bare `docker run` gets.
ENV ROLE=api
ENV PORT=8080
ENV PYTHONPATH=/home/app/src
EXPOSE 8080

CMD ["python", "-u", "src/app.py"]
