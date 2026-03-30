FROM codercom/example-universal:ubuntu

# Version pins — updated by Renovate
ARG SHFMT_VERSION=3.11.0
ARG TERRAFORM_VERSION=1.12.1
ARG KUBECTL_VERSION=1.33.0
ARG HELM_VERSION=3.17.3
ARG HCLOUD_VERSION=1.53.0

USER root

# Remove stale apt sources from the base image (Yarn GPG key expired)
RUN rm -f /etc/apt/sources.list.d/yarn.list

# ── System packages ──────────────────────────────────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ripgrep \
        fd-find \
        jq \
        shellcheck \
        tmux \
        unzip \
        wget \
        gnupg \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI (official apt repo) ───────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Binary installs ───────────────────────────────────────────────────────────
# shfmt
RUN curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
        -o /usr/local/bin/shfmt \
    && chmod +x /usr/local/bin/shfmt

# Terraform
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Helm
RUN curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

# hcloud
RUN curl -fsSL "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz" \
        -o /tmp/hcloud.tar.gz \
    && tar -xzf /tmp/hcloud.tar.gz -C /usr/local/bin hcloud \
    && rm /tmp/hcloud.tar.gz

# ── npm global tools ──────────────────────────────────────────────────────────
RUN npm install -g wrangler gitnexus

# ── User-level tools (as coder) ───────────────────────────────────────────────
USER coder

# uv
RUN curl -fsSL https://astral.sh/uv/install.sh | sh

# ruff via uv tool install
RUN ~/.local/bin/uv tool install ruff

# RTK context compression
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
