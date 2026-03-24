terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.13"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "docker" {}

locals {
  setup_script = file("setup.sh")
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

data "coder_parameter" "system_prompt" {
  name         = "system_prompt"
  display_name = "System Prompt"
  type         = "string"
  form_type    = "textarea"
  default      = ""
  mutable      = false
  description  = "System prompt for Claude Code agent"
}

data "coder_parameter" "setup_script" {
  name         = "setup_script"
  display_name = "Setup Script"
  type         = "string"
  form_type    = "textarea"
  default      = local.setup_script
  mutable      = false
  description  = "Post-install script for tool setup"
}

data "coder_parameter" "container_image" {
  name         = "container_image"
  display_name = "Container Image"
  type         = "string"
  form_type    = "input"
  default      = "codercom/example-universal:ubuntu"
  mutable      = false
  description  = "Docker image for workspace"
}

data "coder_parameter" "dotfiles_repo" {
  name         = "dotfiles_repo"
  display_name = "Dotfiles Repo"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "Git URL for dotfiles repo (leave empty for clean workspace)"
}

data "coder_parameter" "preview_port" {
  name         = "preview_port"
  display_name = "Preview Port"
  type         = "number"
  form_type    = "input"
  default      = "8080"
  mutable      = false
  description  = "Port for the preview app"
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
    min   = 1
    max   = 48
    error = "Memory must be between 1 and 48 GB"
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

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

data "coder_workspace_preset" "dev_machine" {
  name    = "Dev Machine"
  default = true
  parameters = {
    system_prompt   = ""
    setup_script    = local.setup_script
    container_image = "codercom/example-universal:ubuntu"
    preview_port    = "8080"
    mem_limit_gb    = "16"
    cpu_weight      = "8"
  }
}

data "coder_workspace_preset" "devops_task" {
  name = "DevOps Task"
  parameters = {
    system_prompt   = <<-EOT
      -- Framing --
      You are a DevOps/Cloud engineer assistant running inside a Coder Workspace.
      You provide status updates via Coder MCP. Stay on track, debug freely,
      but when your approach fails, check with the user before switching strategy.

      -- Environment --
      - Linux x86_64 container on OVH RISE-S (Ryzen 9700X, 64 GB RAM)
      - Tools: terraform, kubectl, helm, gh, rg, fd, jq, shellcheck, shfmt, uv, ruff, python, node, go, rust
      - Working directory: /home/coder/projects
      - Git identity is pre-configured from Coder account

      -- Guidelines --
      - Follow the project's CLAUDE.md if present
      - Conventional Commits, feature branches, no push to main
      - Security: never hardcode secrets, use env vars
      - German responses, English code/commits
    EOT
    setup_script    = local.setup_script
    container_image = "codercom/example-universal:ubuntu"
    preview_port    = "8080"
    mem_limit_gb    = "8"
    cpu_weight      = "4"
  }
}

data "coder_workspace_preset" "clean" {
  name = "Clean Workspace"
  parameters = {
    system_prompt   = ""
    setup_script    = local.setup_script
    container_image = "codercom/example-universal:ubuntu"
    preview_port    = "8080"
    mem_limit_gb    = "4"
    cpu_weight      = "2"
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
# Claude Code module
# ---------------------------------------------------------------------------

module "claude-code" {
  count               = data.coder_workspace.me.start_count
  source              = "registry.coder.com/coder/claude-code/coder"
  version             = "4.8.1"
  agent_id            = coder_agent.main.id
  workdir             = "/home/coder/projects"
  order               = 999
  claude_api_key      = ""
  ai_prompt           = data.coder_task.me.prompt
  system_prompt       = data.coder_parameter.system_prompt.value
  model               = "sonnet"
  permission_mode     = "plan"
  post_install_script = data.coder_parameter.setup_script.value
}

# ---------------------------------------------------------------------------
# Code Server module
# ---------------------------------------------------------------------------

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder/projects"
  order    = 1
  settings = {
    "workbench.colorTheme" = "Default Dark Modern"
  }
}

# ---------------------------------------------------------------------------
# Coder Agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi
    mkdir -p /home/coder/projects
  EOT
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    DOTFILES_REPO       = data.coder_parameter.dotfiles_repo.value
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

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "3_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "4_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "5_load_avg_host"
    script       = "echo \"`cat /proc/loadavg | awk '{ print $1 }'` `nproc`\" | awk '{ printf \"%0.2f\", $1/$2 }'"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "6_swap_usage_host"
    script       = "free -b | awk '/^Swap/ { printf(\"%.1f/%.1f\", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'"
    interval     = 10
    timeout      = 1
  }
}

# ---------------------------------------------------------------------------
# Docker Volume (persistent home)
# ---------------------------------------------------------------------------

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle {
    ignore_changes = all
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
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# ---------------------------------------------------------------------------
# Docker Container
# ---------------------------------------------------------------------------

resource "docker_container" "workspace" {
  count      = data.coder_workspace.me.start_count
  image      = data.coder_parameter.container_image.value
  name       = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname   = data.coder_workspace.me.name
  user       = "coder"
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  memory     = data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024
  cpu_shares = data.coder_parameter.cpu_weight.value * 1024

  # Resource limits and swap prevention
  memory_swap = data.coder_parameter.mem_limit_gb.value * 1024 * 1024 * 1024
  # NOTE: no-new-privileges and cap_drop are omitted because the workspace
  # needs sudo for tool installation (apt-get, binary installs to /usr/local/bin)
  # and the Coder agentapi module uses sudo internally.

  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
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
}

# ---------------------------------------------------------------------------
# Preview App
# ---------------------------------------------------------------------------

resource "coder_app" "preview" {
  agent_id     = coder_agent.main.id
  slug         = "preview"
  display_name = "Preview"
  icon         = "${data.coder_workspace.me.access_url}/emojis/1f50e.png"
  url          = "http://localhost:${data.coder_parameter.preview_port.value}"
  share        = "authenticated"
  subdomain    = true
  open_in      = "tab"
  order        = 0
  healthcheck {
    url       = "http://localhost:${data.coder_parameter.preview_port.value}/"
    interval  = 5
    threshold = 15
  }
}
