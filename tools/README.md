# Linnix Tools

Helper utilities and CLI tools for operating and debugging Linnix.

## Overview

This directory contains user-facing utilities that complement the main `linnix-cli` application. These tools provide convenient wrappers, analysis utilities, and operational helpers for working with Linnix.

## Available Tools

### `api_explorer.sh`

Interactive API explorer for discovering and testing Linnix APIs.

**Usage:**
```bash
# Show help
./tools/api_explorer.sh help

# List all API categories
./tools/api_explorer.sh list

# List endpoints in a specific category
./tools/api_explorer.sh list "System & Status"

# Show all endpoints with details
./tools/api_explorer.sh all

# Search for endpoints
./tools/api_explorer.sh search incident
./tools/api_explorer.sh search process

# Test an API endpoint
./tools/api_explorer.sh test status
./tools/api_explorer.sh test system
./tools/api_explorer.sh test incidents
./tools/api_explorer.sh test incidents/33

# Enter interactive mode
./tools/api_explorer.sh interactive
```

**Interactive Mode:**
Enter an interactive shell for exploring APIs:
- `list` - List categories
- `list <category>` - List endpoints in category
- `search <query>` - Search endpoints
- `test <endpoint>` - Test an endpoint
- `help` - Show commands
- `exit` - Exit interactive mode

**Environment Variables:**
- `LINNIX_URL` - Base URL (default: http://127.0.0.1:3000)
- `LINNIX_COLOR` - Enable colors (default: true)

### `view_incidents.sh`

View and monitor Linnix incidents in various formats.

**Usage:**
```bash
# List recent incidents in table format
./tools/view_incidents.sh list

# Show detailed view of latest incident
./tools/view_incidents.sh detail

# Stream new incidents in real-time (Ctrl+C to stop)
./tools/view_incidents.sh watch

# Pretty-print incidents as JSON
./tools/view_incidents.sh json           # All incidents
./tools/view_incidents.sh json 5         # First 5 incidents (limit)
./tools/view_incidents.sh json 33        # Specific incident #33 (ID)
./tools/view_incidents.sh json "#5"      # Force ID lookup for incident #5
```

**JSON Mode:**
- Numbers 1-20 are treated as limits (e.g., `json 5` = first 5 incidents)
- Numbers >20 are treated as incident IDs (e.g., `json 33` = incident #33)
- Use `#` prefix to force ID lookup (e.g., `json "#5"` = incident #5)

**Requirements:**
- Linnix cognitod running on http://127.0.0.1:3000
- Python 3 (for JSON formatting)
- curl

## Directory Purpose

**`tools/`** vs **`scripts/`** vs **`linnix-cli/`**:

- **`linnix-cli/`** - Main compiled CLI application (Rust)
- **`scripts/`** - Build, installation, and development automation scripts
- **`tools/`** - User-facing helper utilities for operators and developers

## Adding New Tools

When adding new tools to this directory:

1. Make the script executable: `chmod +x tools/your_tool.sh`
2. Add usage documentation to this README
3. Follow naming convention: lowercase with underscores
4. Include a help message when run without arguments

## Contributing

These tools should be:
- **User-focused**: Designed for operators and users, not just developers
- **Self-contained**: Minimal dependencies, clear error messages
- **Well-documented**: Include help text and examples
