terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.29"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "docker" {}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

data "coder_external_auth" "github" {
  id = "github"
}

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Repository URL"
  type         = "string"
  form_type    = "input"
  mutable      = true
  description  = "Git repository URL to clone and work on"
}

data "coder_parameter" "branch" {
  name         = "branch"
  display_name = "Branch"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "Branch to check out (leave empty for default branch)"
}

data "coder_parameter" "system_prompt" {
  name         = "system_prompt"
  display_name = "System Prompt"
  type         = "string"
  form_type    = "textarea"
  mutable      = false
  description  = "System prompt for the agent"
  default      = <<-EOT
    -- Framing --
    You are a background coding agent running inside a Coder Task workspace.
    Your job is to implement the requested change and open a PR.

    -- Environment --
    - Linux x86_64 container on OVH RISE-S (Ryzen 9700X, 64 GB RAM)
    - Tools: gh, git, rg, fd, jq, shellcheck, terraform, kubectl, helm
    - Docker access via host socket
    - Git identity is pre-configured from Coder account
    - GITHUB_TOKEN is set — use `gh` CLI for all GitHub operations

    -- Workflow --
    1. Read the project's CLAUDE.md / AGENTS.md if present
    2. Create a feature branch: feat/<short-description>
    3. Implement the solution with minimal, correct, reviewable changes
    4. Run available checks (lint, typecheck, tests) and fix failures
    5. Commit with Conventional Commits
    6. Push and open a PR via `gh pr create`

    -- Guidelines --
    - Conventional Commits, feature branches, never push to main
    - Security: never hardcode secrets, use env vars
    - German responses when communicating, English code/commits
    - If stuck or unclear, report failure state and describe the blocker
  EOT
}

data "coder_parameter" "mem_limit_gb" {
  name         = "mem_limit_gb"
  display_name = "Memory Limit (GB)"
  type         = "number"
  form_type    = "input"
  default      = "8"
  mutable      = false
  description  = "Memory limit in GB"
  validation {
    min   = 2
    max   = 32
    error = "Memory must be between 2 and 32 GB"
  }
}

data "coder_parameter" "cpu_weight" {
  name         = "cpu_weight"
  display_name = "CPU Weight"
  type         = "number"
  form_type    = "input"
  default      = "4"
  mutable      = false
  description  = "Relative CPU priority (factor for cpu_shares)"
  validation {
    min   = 1
    max   = 16
    error = "CPU weight must be between 1 and 16"
  }
}

data "coder_parameter" "anthropic_api_key" {
  name         = "anthropic_api_key"
  display_name = "Anthropic API Key"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "API key for Claude (leave empty to use OAuth)"
  ephemeral    = true
}

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

data "coder_workspace_preset" "standard" {
  name    = "Standard Task"
  default = true
  parameters = {
    branch        = ""
    system_prompt = data.coder_parameter.system_prompt.default
    mem_limit_gb  = "8"
    cpu_weight    = "4"
  }
}

data "coder_workspace_preset" "heavy" {
  name = "Heavy Task"
  parameters = {
    branch        = ""
    system_prompt = data.coder_parameter.system_prompt.default
    mem_limit_gb  = "16"
    cpu_weight    = "8"
  }
}

# ---------------------------------------------------------------------------
# AI Task
# ---------------------------------------------------------------------------

resource "coder_ai_task" "task" {
  count  = data.coder_workspace.me.start_count
  app_id = module.claude-code[count.index].task_app_id
}

# ---------------------------------------------------------------------------
# Official Modules
# ---------------------------------------------------------------------------

module "git-config" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-config/coder"
  version  = "1.0.33"
  agent_id = coder_agent.main.id
}

module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/dotfiles/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id
}

module "git-clone" {
  count             = data.coder_workspace.me.start_count
  source            = "registry.coder.com/coder/git-clone/coder"
  version           = "1.2.3"
  agent_id          = coder_agent.main.id
  url               = data.coder_parameter.repo_url.value
  branch_name       = data.coder_parameter.branch.value
  base_dir          = "/home/coder"
  post_clone_script = "touch /tmp/coder-git-clone-done"
}

module "claude-code" {
  count              = data.coder_workspace.me.start_count
  source             = "registry.coder.com/coder/claude-code/coder"
  version            = "4.8.2"
  agent_id           = coder_agent.main.id
  workdir            = module.git-clone[0].repo_dir
  order              = 999
  claude_api_key     = data.coder_parameter.anthropic_api_key.value
  ai_prompt          = data.coder_task.me.prompt
  system_prompt      = data.coder_parameter.system_prompt.value
  model              = "sonnet"
  permission_mode    = "bypassPermissions"
  pre_install_script = "timeout 300 sh -c 'while [ ! -f /tmp/coder-git-clone-done ]; do sleep 1; done'"
}

# ---------------------------------------------------------------------------
# Coder Agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  env = {
    GITHUB_TOKEN = data.coder_external_auth.github.access_token
    DOCKER_HOST  = "unix:///var/run/docker.sock"
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# ---------------------------------------------------------------------------
# Docker Container (ephemeral — no persistent volume)
# ---------------------------------------------------------------------------

resource "docker_container" "workspace" {
  count       = data.coder_workspace.me.start_count
  image       = "ghcr.io/swatpeacekeeper/claude-workspace:latest"
  name        = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname    = data.coder_workspace.me.name
  user        = "coder"
  entrypoint  = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env         = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  memory      = data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024
  cpu_shares  = data.coder_parameter.cpu_weight.value * 1024
  memory_swap = data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
  labels {
    label = "coder.template"
    value = "claude-pr"
  }
}
