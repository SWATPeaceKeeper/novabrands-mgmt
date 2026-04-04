FROM codercom/enterprise-base:ubuntu

# ── Version pins (updated by Renovate) ───────────────────────────────────────
ARG SHFMT_VERSION=3.11.0
ARG TERRAFORM_VERSION=1.12.1
ARG KUBECTL_VERSION=1.33.0
ARG HELM_VERSION=3.17.3
ARG HCLOUD_VERSION=1.53.0
ARG NODE_MAJOR=22
ARG GO_VERSION=1.24.2
ARG DOTNET_VERSION=9.0

USER root

# ── Upgrade base + install language runtimes ─────────────────────────────────
# Base image includes: python3, build-essential, git, jq, curl, wget, unzip
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        ripgrep fd-find shellcheck tmux gnupg ca-certificates cmake \
        python3-venv python3-dev \
        ruby ruby-dev \
        php-cli php-mbstring php-xml php-curl \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js (via nodesource) ────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Go ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
        -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# ── .NET SDK ─────────────────────────────────────────────────────────────────
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel ${DOTNET_VERSION} --install-dir /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && rm /tmp/dotnet-install.sh
ENV DOTNET_ROOT="/usr/share/dotnet"

# ── Rust (system-wide via rustup) ────────────────────────────────────────────
ENV RUSTUP_HOME="/usr/local/rustup" CARGO_HOME="/usr/local/cargo"
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path \
        --default-toolchain stable --profile minimal \
    && chmod -R a+r /usr/local/rustup /usr/local/cargo
ENV PATH="/usr/local/cargo/bin:${PATH}"

# ── GitHub CLI ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── DevOps binary tools ──────────────────────────────────────────────────────
RUN curl -fsSL "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
        -o /usr/local/bin/shfmt && chmod +x /usr/local/bin/shfmt \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/terraform.zip && unzip -q /tmp/terraform.zip -d /usr/local/bin && rm /tmp/terraform.zip \
    && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
        -o /tmp/helm.tar.gz && tar -xzf /tmp/helm.tar.gz -C /tmp \
        && mv /tmp/linux-amd64/helm /usr/local/bin/helm && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64 \
    && curl -fsSL "https://github.com/hetznercloud/cli/releases/download/v${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz" \
        -o /tmp/hcloud.tar.gz && tar -xzf /tmp/hcloud.tar.gz -C /usr/local/bin hcloud && rm /tmp/hcloud.tar.gz

# ── npm global tools ─────────────────────────────────────────────────────────
RUN npm install -g wrangler gitnexus

# ── Playwright Chromium (system deps) ────────────────────────────────────────
RUN npx playwright install-deps chromium

# ── User-level tools (as coder) ──────────────────────────────────────────────
USER coder
ENV PATH="/home/coder/.local/bin:${PATH}"

RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && uv tool install ruff

RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

# ── Playwright Chromium browser ──────────────────────────────────────────────
RUN npx playwright install chromium
