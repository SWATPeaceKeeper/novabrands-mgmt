# Claude Workspace Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Coder template that provisions local Docker workspaces for Claude Code development on the OVH RISE-S server.

**Architecture:** Terraform template using `kreuzwerker/docker` provider to create containers from `codercom/example-universal:ubuntu`. Tools installed via idempotent `setup.sh` (hash-based marker). Optional dotfiles repo for personal configs. Three presets (Dev Machine, DevOps Task, Clean) with different resource limits and system prompts.

**Tech Stack:** Terraform (HCL), Bash, Coder Registry Modules (claude-code v4.8.1+, code-server ~>1.0), Docker Provider (kreuzwerker/docker)

**Spec:** `docs/superpowers/specs/2026-03-23-claude-workspace-template-design.md`

---

## File Structure

```
coder/templates/claude-workspace/
  main.tf      # Terraform template: providers, parameters, presets, modules,
               #   agent, container, volume, apps
  setup.sh     # Tool installation script (idempotent, hash-based marker)
  README.md    # Template documentation for Coder users
```

All three files are new. No existing files are modified.

---

### Task 1: Create setup.sh (Tool Installation Script)

**Files:**
- Create: `coder/templates/claude-workspace/setup.sh`

This is the foundation — both main.tf and the presets reference it via `file("setup.sh")`.

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p coder/templates/claude-workspace
```

- [ ] **Step 2: Write setup.sh**

Create `coder/templates/claude-workspace/setup.sh` with these sections in order:

1. **Header:** `#!/usr/bin/env bash` + `set -euo pipefail`
2. **Hash-based marker:** Compute SHA256 of the script itself, truncate to first 8 characters, check if marker `$HOME/.coder-tools-v<hash8>` exists. If yes, skip tool installation.
3. **Tool installation block** (runs only when marker missing):
   - `sudo apt-get update && sudo apt-get install -y ripgrep fd-find jq shellcheck tmux unzip wget gnupg`
   - shfmt: Download latest release from `mvdan/sh` GitHub (linux_amd64 binary) → `/usr/local/bin/shfmt`
   - uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - ruff: `$HOME/.local/bin/uv tool install ruff`
   - gh (GitHub CLI): Add official apt repo, install via apt
   - terraform: Download latest release zip from HashiCorp → `/usr/local/bin/terraform`
   - kubectl: Download stable release from dl.k8s.io → `/usr/local/bin/kubectl`
   - helm: `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`
   - Write marker file after all installs succeed
4. **Dotfiles section** (runs every start):
   - Read `DOTFILES_REPO` env var (may be empty)
   - If set and `$HOME/.dotfiles` does not exist: `git clone`
   - If set and `$HOME/.dotfiles` exists: `git pull --ff-only` (ignore errors)
   - If `$HOME/.dotfiles/bootstrap.sh` exists and is executable: run it

- [ ] **Step 3: Lint with shellcheck**

Run: `shellcheck coder/templates/claude-workspace/setup.sh`
Expected: No errors, no warnings.

- [ ] **Step 4: Format with shfmt**

Run: `shfmt -d coder/templates/claude-workspace/setup.sh`
Expected: No diff (already formatted). If diff shown, run `shfmt -w coder/templates/claude-workspace/setup.sh`.

- [ ] **Step 5: Commit**

```bash
git add coder/templates/claude-workspace/setup.sh
git commit -m "feat(coder): add setup.sh for claude-workspace template

Idempotent tool installation with hash-based marker.
Installs: rg, fd, jq, shellcheck, shfmt, tmux, uv, ruff,
gh, terraform, kubectl, helm.
Optional dotfiles repo clone + bootstrap."
```

---

### Task 2: Create main.tf (Terraform Template)

**Files:**
- Create: `coder/templates/claude-workspace/main.tf`

This is the core template. Build it in logical sections.

- [ ] **Step 1: Write the providers and data sources block**

Top of `main.tf`:
- `terraform` block with `coder/coder` (>= 2.13) and `kreuzwerker/docker` providers
- `provider "docker" {}` (no host — inherits DOCKER_HOST from environment)
- `data "coder_provisioner" "me" {}`
- `data "coder_workspace" "me" {}`
- `data "coder_workspace_owner" "me" {}`
- `data "coder_task" "me" {}`

- [ ] **Step 2: Write the parameters block**

Seven `data "coder_parameter"` blocks:
- `system_prompt`: string, textarea, default `""`, mutable false
- `setup_script`: string, textarea, default `file("setup.sh")`, mutable false
- `container_image`: string, default `"codercom/example-universal:ubuntu"`, mutable false
- `dotfiles_repo`: string, default `""`, mutable false, description mentions "leave empty for clean workspace"
- `preview_port`: number, default `"8080"`, mutable true
- `mem_limit_gb`: number, default `"8"`, mutable false
- `cpu_weight`: number, default `"4"`, mutable false

- [ ] **Step 3: Write the presets block**

Three `data "coder_workspace_preset"` blocks:

**"Dev Machine"** (default = true):
- system_prompt: `""`
- setup_script: `file("setup.sh")`
- container_image: `"codercom/example-universal:ubuntu"`
- dotfiles_repo: `""`
- preview_port: `"8080"`
- mem_limit_gb: `"16"`
- cpu_weight: `"8"`

**"DevOps Task"**:
- system_prompt: Multi-line DevOps context (Framing, Environment, Guidelines from spec section 5.2)
- setup_script: `file("setup.sh")`
- container_image: `"codercom/example-universal:ubuntu"`
- dotfiles_repo: `""`
- preview_port: `"8080"`
- mem_limit_gb: `"8"`
- cpu_weight: `"4"`

**"Clean Workspace"**:
- system_prompt: `""`
- setup_script: `file("setup.sh")`
- container_image: `"codercom/example-universal:ubuntu"`
- dotfiles_repo: `""`
- preview_port: `"8080"`
- mem_limit_gb: `"4"`
- cpu_weight: `"2"`

- [ ] **Step 4: Write the AI task and modules block**

- `resource "coder_ai_task" "task"` with count = start_count, app_id from claude-code module
- `module "claude-code"` from registry (v4.8.1+):
  - agent_id, workdir `/home/coder/projects`, order 999
  - claude_api_key `""`, ai_prompt from coder_task, system_prompt from parameter
  - model `"sonnet"`, permission_mode `"plan"`
  - post_install_script from setup_script parameter
- `module "code-server"` from registry (~>1.0):
  - agent_id, folder `/home/coder/projects`, order 1
  - settings with dark theme

- [ ] **Step 5: Write the coder_agent resource**

`resource "coder_agent" "main"`:
- arch from provisioner, os "linux"
- startup_script: create `/home/coder/projects` dir, copy skel on first start
- env block: GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL from workspace_owner
- env block: DOTFILES_REPO from dotfiles_repo parameter (for setup.sh to read)
- 7 metadata blocks: CPU Usage, RAM Usage, Home Disk, CPU Usage (Host), Memory Usage (Host), Load Average (Host), Swap Usage (Host) — same as reference template

- [ ] **Step 6: Write the docker resources block**

- `resource "docker_volume" "home_volume"`: lifecycle ignore_changes, labels for owner/workspace tracking
- `resource "docker_container" "workspace"`:
  - count = start_count
  - image from container_image parameter
  - name: `coder-${owner}-${workspace}`
  - hostname from workspace name
  - user `"coder"`
  - entrypoint with host.docker.internal replacement
  - env: CODER_AGENT_TOKEN
  - host block for host.docker.internal
  - volumes: /home/coder from home_volume
  - memory: `data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024` (bytes)
  - cpu_shares: `data.coder_parameter.cpu_weight.value * 1024`
  - labels for owner/workspace tracking

- [ ] **Step 7: Write the preview app resource**

`resource "coder_app" "preview"`:
- agent_id, slug "preview", display_name "Preview"
- url from preview_port parameter
- share "authenticated", subdomain true, open_in "tab", order 0
- healthcheck on the preview port

- [ ] **Step 8: Validate Terraform syntax**

Run: `terraform -chdir=coder/templates/claude-workspace fmt -check`
Expected: No files need formatting.

Run: `terraform -chdir=coder/templates/claude-workspace validate`
Note: This will fail because the Coder providers aren't available locally. That's expected — we validate syntax, not provider availability. If `fmt -check` passes and there are no HCL parse errors, the template is syntactically correct.

- [ ] **Step 9: Commit**

```bash
git add coder/templates/claude-workspace/main.tf
git commit -m "feat(coder): add main.tf for claude-workspace template

Terraform template with:
- claude-code module (Tasks support)
- code-server module (VS Code in browser)
- 3 presets: Dev Machine (16GB), DevOps Task (8GB), Clean (4GB)
- Optional dotfiles repo parameter
- Parametrized resource limits (memory hard, CPU soft)
- Preview app on configurable port"
```

---

### Task 3: Create README.md (Template Documentation)

**Files:**
- Create: `coder/templates/claude-workspace/README.md`

- [ ] **Step 1: Write README.md**

Sections:
1. **Title + description:** Claude Workspace — Docker-based dev environments for Claude Code
2. **Prerequisites:** Coder with Docker socket access (coder-socket-proxy), Claude account (OAuth login)
3. **Presets table:** Dev Machine, DevOps Task, Clean with their resource limits
4. **Parameters table:** All 7 parameters with descriptions
5. **First-time setup:**
   - Pre-pull image: `docker pull codercom/example-universal:ubuntu`
   - Create workspace, select preset
   - Run `claude login` on first start
   - Optionally set dotfiles_repo to your config repo
6. **Dotfiles integration:** Explain how bootstrap.sh is called, link to claude-pi as example
7. **Lifecycle recommendations:** Auto-stop/delete guidance per preset

- [ ] **Step 2: Commit**

```bash
git add coder/templates/claude-workspace/README.md
git commit -m "docs(coder): add README for claude-workspace template"
```

---

### Task 4: Validate and Final Commit

**Files:**
- Verify: all three files in `coder/templates/claude-workspace/`

- [ ] **Step 1: Verify file structure**

Run: `find coder/templates/claude-workspace -type f | sort`
Expected:
```
coder/templates/claude-workspace/README.md
coder/templates/claude-workspace/main.tf
coder/templates/claude-workspace/setup.sh
```

- [ ] **Step 2: Re-run shellcheck on setup.sh**

Run: `shellcheck coder/templates/claude-workspace/setup.sh`
Expected: Clean (exit 0).

- [ ] **Step 3: Re-run terraform fmt**

Run: `terraform -chdir=coder/templates/claude-workspace fmt -check`
Expected: Clean (exit 0). If not, run `terraform fmt` and amend the last commit.

- [ ] **Step 4: Review all files one more time**

Read all three files and verify:
- setup.sh: Hash-based marker, all tools from spec, dotfiles integration
- main.tf: All 7 parameters, 3 presets, claude-code module, code-server module, preview app, resource limits in bytes, cpu_shares with weight
- README.md: Accurate descriptions matching main.tf

No commit needed — this is a review step.
