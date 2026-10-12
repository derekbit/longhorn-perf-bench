FROM python:3.12-slim-bookworm

ARG KUBECTL_VERSION=v1.31.2
ARG YQ_VERSION=v4.45.4

# libpango*/libharfbuzz-subset0/fonts are weasyprint's runtime deps (PDF report).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl jq \
        libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz-subset0 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    && curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
    && chmod +x /usr/local/bin/kubectl /usr/local/bin/yq

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY run.sh generate_report.py local-path-storage.yaml docker-entrypoint.sh ./
COPY lib ./lib
COPY storageclass ./storageclass

# Mount the directory holding config.json (and receiving results/) here.
WORKDIR /work
ENTRYPOINT ["/app/docker-entrypoint.sh"]
