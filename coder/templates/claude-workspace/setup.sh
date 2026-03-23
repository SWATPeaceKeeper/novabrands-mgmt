#!/usr/bin/env bash
set -euo pipefail

# Idempotent tool installer for Coder claude-workspace template.
# Runs as post_install_script via the Claude Code Coder module.

SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -c1-8 || echo "unknown")
MARKER="$HOME/.coder-tools-v${SCRIPT_HASH}"

install_tools() {
	echo "==> Installing system packages..."
	sudo apt-get update
	sudo apt-get install -y \
		ripgrep fd-find jq shellcheck tmux unzip wget gnupg

	echo "==> Installing shfmt..."
	local shfmt_url
	shfmt_url=$(
		wget -qO- https://api.github.com/repos/mvdan/sh/releases/latest |
			jq -r '.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url'
	)
	[[ -n "$shfmt_url" ]] || {
		echo "ERROR: Failed to resolve shfmt download URL"
		exit 1
	}
	sudo wget -qO /usr/local/bin/shfmt "$shfmt_url"
	sudo chmod +x /usr/local/bin/shfmt

	echo "==> Installing uv..."
	curl -LsSf https://astral.sh/uv/install.sh | sh

	echo "==> Installing ruff via uv..."
	"$HOME/.local/bin/uv" tool install ruff

	echo "==> Installing GitHub CLI..."
	sudo mkdir -p /etc/apt/keyrings
	wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg |
		sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
	sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
		sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
	sudo apt-get update
	sudo apt-get install -y gh

	echo "==> Installing Terraform..."
	local tf_version
	tf_version=$(
		wget -qO- https://api.github.com/repos/hashicorp/terraform/releases/latest |
			jq -r '.tag_name' | sed 's/^v//'
	)
	[[ -n "$tf_version" ]] || {
		echo "ERROR: Failed to resolve Terraform version"
		exit 1
	}
	wget -qO /tmp/terraform.zip \
		"https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip"
	sudo unzip -o /tmp/terraform.zip -d /usr/local/bin
	rm -f /tmp/terraform.zip

	echo "==> Installing kubectl..."
	local kubectl_version
	kubectl_version=$(wget -qO- https://dl.k8s.io/release/stable.txt)
	[[ -n "$kubectl_version" ]] || {
		echo "ERROR: Failed to resolve kubectl version"
		exit 1
	}
	sudo wget -qO /usr/local/bin/kubectl \
		"https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
	sudo chmod +x /usr/local/bin/kubectl

	echo "==> Installing Helm..."
	curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

	touch "$MARKER"
	echo "==> Tool installation complete (marker: ${MARKER})"
}

apply_dotfiles() {
	DOTFILES_REPO="${DOTFILES_REPO:-}"
	if [[ -z "$DOTFILES_REPO" ]]; then
		return
	fi

	if [[ ! -d "$HOME/.dotfiles" ]]; then
		echo "==> Cloning dotfiles from ${DOTFILES_REPO}..."
		git clone "$DOTFILES_REPO" "$HOME/.dotfiles"
	else
		echo "==> Updating dotfiles..."
		git -C "$HOME/.dotfiles" pull --ff-only 2>/dev/null || true
	fi

	if [[ -x "$HOME/.dotfiles/bootstrap.sh" ]]; then
		echo "==> Running dotfiles bootstrap..."
		"$HOME/.dotfiles/bootstrap.sh"
	fi
}

# --- Main ---

if [[ -f "$MARKER" ]]; then
	echo "==> Tools already installed (marker: ${MARKER}), skipping."
else
	install_tools
fi

apply_dotfiles
