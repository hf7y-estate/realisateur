# vault -- the archive as a service. After provision/dexter/roster: the image is
# RUNTIME, the mount is STATE, and nothing is pip-installed.
#
# git IS the runtime here, not a build tool: the service commits and pushes.
FROM python:3.11-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -s /bin/bash vault && mkdir -p /data && chown vault:vault /data

COPY vault_server.py /opt/vault/vault_server.py
RUN chown -R vault:vault /opt/vault

USER vault
ENV VAULT_DIR=/data/vault
EXPOSE 8647
CMD ["python", "/opt/vault/vault_server.py"]
