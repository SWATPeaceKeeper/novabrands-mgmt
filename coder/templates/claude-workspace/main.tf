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

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

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
  default      = ""
  mutable      = true
  description  = "Git repository URL to clone on startup (leave empty to skip)"
}

data "coder_parameter" "preview_port" {
  name         = "preview_port"
  display_name = "Preview Port"
  type         = "number"
  form_type    = "input"
  default      = "8080"
  mutable      = true
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
    min   = 2
    max   = 48
    error = "Memory must be between 2 and 48 GB"
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

# --- Ephemeral API keys ---

data "coder_parameter" "claude_code_oauth_token" {
  name         = "claude_code_oauth_token"
  display_name = "Claude Code OAuth Token"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "Generate via claude setup-token (leave empty to login interactively)"
  ephemeral    = true
}

data "coder_parameter" "hcloud_api_token" {
  name         = "hcloud_api_token"
  display_name = "Hetzner Cloud Token"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "Hetzner Cloud API token for hcloud CLI"
  ephemeral    = true
}

data "coder_parameter" "cloudflare_api_token" {
  name         = "cloudflare_api_token"
  display_name = "Cloudflare API Token"
  type         = "string"
  form_type    = "input"
  default      = ""
  mutable      = true
  description  = "Cloudflare API token for wrangler CLI"
  ephemeral    = true
}

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------

data "coder_workspace_preset" "dev_machine" {
  name    = "Dev Machine"
  default = true
  parameters = {
    repo_url     = ""
    preview_port = "8080"
    mem_limit_gb = "16"
    cpu_weight   = "8"
  }
}

data "coder_workspace_preset" "clean" {
  name = "Clean Workspace"
  parameters = {
    repo_url     = ""
    preview_port = "8080"
    mem_limit_gb = "4"
    cpu_weight   = "2"
  }
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
  count    = data.coder_workspace.me.start_count != 0 && data.coder_parameter.repo_url.value != "" ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "1.2.3"
  agent_id = coder_agent.main.id
  url      = data.coder_parameter.repo_url.value
  base_dir = "/home/coder"
}

module "claude-code" {
  count                   = data.coder_workspace.me.start_count
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "4.8.2"
  agent_id                = coder_agent.main.id
  workdir                 = try(module.git-clone[0].repo_dir, "/home/coder")
  order                   = 999
  claude_code_oauth_token = data.coder_parameter.claude_code_oauth_token.value
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "1.4.3"
  agent_id = coder_agent.main.id
  folder   = try(module.git-clone[0].repo_dir, "/home/coder")
  order    = 1
  settings = {
    "workbench.colorTheme" = "Default Dark Modern"
  }
}

module "filebrowser" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/filebrowser/coder"
  version  = "1.1.4"
  agent_id = coder_agent.main.id
  order    = 2
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
  EOT
  env = {
    GITHUB_TOKEN         = data.coder_external_auth.github.access_token
    DOCKER_HOST          = "unix:///var/run/docker.sock"
    HCLOUD_TOKEN         = data.coder_parameter.hcloud_api_token.value
    CLOUDFLARE_API_TOKEN = data.coder_parameter.cloudflare_api_token.value
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
}

# ---------------------------------------------------------------------------
# Docker Container
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
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
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
