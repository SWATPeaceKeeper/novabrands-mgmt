# Claude Workspace

Docker-based development environments for Claude Code on OVH RISE-S.

## What's included

- **Claude Code** with Tasks support (via Coder module, OAuth login — no API key required)
- **VS Code in browser** (code-server, opens in `/home/coder/projects`)
- **DevOps tooling:** terraform, kubectl, helm, gh, rg, fd, jq, shellcheck, shfmt, uv, ruff
- **Persistent home directory** (Docker volume, survives stop/start)
- **Optional dotfiles repo** for personal shell configs and tooling
- **SSH, VS Code Desktop, and Claude Code CLI** access via Coder

## Presets

| Preset | RAM | CPU Weight | System Prompt | Use Case |
|--------|-----|------------|---------------|----------|
| Dev Machine (default) | 16 GB | 8 | None (uses CLAUDE.md) | Persistent workspace |
| DevOps Task | 8 GB | 4 | DevOps context | Short-lived tasks |
| Clean Workspace | 4 GB | 2 | None | Experiments, onboarding |

CPU weight maps to Docker `cpu_shares` (weight × 1024). It is a relative priority, not a hard limit.

## Prerequisites

- Coder server with Docker socket access (via `coder-socket-proxy`)
- Claude account (Max or Pro plan) for OAuth login
- GitHub OAuth configured in Coder (required for private repos)
- Base image pre-pulled on the host:

```bash
docker pull codercom/example-universal:ubuntu
```

## Getting started

**Import the template:**

```bash
coder templates push claude-workspace -d coder/templates/claude-workspace
```

**Create a workspace:**

1. Select a preset (or configure parameters manually)
2. Optionally set `dotfiles_repo` to your dotfiles Git URL
3. Start the workspace

**Authenticate Claude Code on first start:**

```bash
claude login
```

The auth token is stored in the home volume and persists across restarts.

## Dotfiles integration

Set the `dotfiles_repo` parameter to a Git URL (SSH or HTTPS). On every start:

- If `~/.dotfiles` does not exist, the repo is cloned there
- If it already exists, `git pull --ff-only` is run
- If `bootstrap.sh` exists in the repo root and is executable, it runs automatically

Example: adapt a `claude-pi` dotfiles repo for x86 containers by removing ARM-specific steps.

## Lifecycle recommendations

Configure these under **Template Settings** in the Coder UI.

| Preset | Auto-stop | Auto-delete |
|--------|-----------|-------------|
| Dev Machine | After 2h inactivity | Never |
| DevOps Task | After 1h inactivity | After 7 days |
| Clean Workspace | After 30min inactivity | After 24h |
