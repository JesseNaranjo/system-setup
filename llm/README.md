# LLM Management Scripts

This directory contains scripts for managing Ollama, a local LLM (Large Language Model) runtime. The scripts provide convenient screen-based environments for running and monitoring Ollama servers.

## Script Overview

| Script | Description | Use Case |
|--------|-------------|----------|
| `ollama-screen.sh` | Launch Ollama in a local screen session | Local development |
| `ollama-remote.sh` | Launch Ollama as a network-accessible server | Remote/API access |
| `_download-ollama-scripts.sh` | Self-updating script manager | Keep scripts current |

## Quick Start

### Local Usage

```bash
# Launch Ollama with monitoring in a screen session
./ollama-screen.sh
```

### Remote Server

```bash
# Launch Ollama accessible on the network (0.0.0.0:11434)
./ollama-remote.sh

# With custom host/port
OLLAMA_HOST="192.168.1.100:11434" ./ollama-remote.sh
```

### Update Scripts

```bash
# Download latest versions from repository
./_download-ollama-scripts.sh
```

## Script Details

### ollama-screen.sh

Launches Ollama in a GNU screen session with a multi-pane layout optimized for local development:

```
┌─────────────────┬─────────────────┐
│  shell (35%)    │     nvtop       │
├─────────────────┤     (GPU)       │
│                 ├─────────────────┤
│  shell          │     htop        │
│                 │     (CPU)       │
│                 ├─────────────────┤
│                 │  ollama serve   │
└─────────────────┴─────────────────┘
```

**Features:**
- Two shell panes for running ollama commands
- GPU monitoring via nvtop
- CPU/memory monitoring via htop
- Ollama server in dedicated pane
- Auto-displays model list on startup

**Generated Config:** `.screenrc-ollama`

### ollama-remote.sh

Launches Ollama as a network-accessible server with monitoring:

```
┌─────────────────┬─────────────────┐
│     nvtop       │                 │
│     (GPU)       │                 │
├─────────────────┤  ollama serve   │
│     htop        │  (0.0.0.0:11434)│
│     (CPU)       │                 │
├─────────────────┤                 │
│     shell       │                 │
└─────────────────┴─────────────────┘
```

**Features:**
- Binds to all interfaces (0.0.0.0) for network access
- GPU and CPU monitoring on the left
- Server output on the right for visibility
- Shell pane for administration

**Environment Variables:**

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_HOST` | Host and port to bind | `0.0.0.0:11434` |

**Generated Config:** `.screenrc-ollama-remote`

### _download-ollama-scripts.sh

Self-updating script manager that keeps Ollama scripts current:

- Self-updates before processing other scripts
- Downloads latest versions from repository
- Shows diffs before overwriting local files
- Prompts for confirmation on each change
- Cleans up obsolete/renamed scripts

## Screen Navigation

Common screen keybindings (prefix: `Ctrl+a`):

| Key | Action |
|-----|--------|
| `Ctrl+a` then `Tab` | Move to next pane |
| `Ctrl+a` then `d` | Detach session |
| `Ctrl+a` then `[` | Enter scroll mode |
| `Ctrl+a` then `?` | Show help |

Reattach to a detached session:
```bash
screen -r
```

## Dependencies

- **ollama** - LLM runtime
- **screen** - Terminal multiplexer
- **nvtop** - GPU monitoring (optional, recommended)
- **htop** - Process monitoring (optional, recommended)
- **curl** or **wget** - Script updates

## Common Commands

Once inside a screen session:

```bash
# List available models
ollama list

# Show running models
ollama ps

# Pull a model
ollama pull llama3.2

# Run a model interactively
ollama run llama3.2

# Serve API (already running in server pane)
# Access at http://localhost:11434/api/generate
```

## API Access (Remote Mode)

When using `ollama-remote.sh`, the API is accessible from other machines:

```bash
# From another machine
curl http://<server-ip>:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Hello, world!"
}'
```
