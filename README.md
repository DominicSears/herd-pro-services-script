# Herd Services Manager

A bash script to manage Laravel Herd services from the command line. It reads your project's `herd.yml` to start and stop services, resolving ports from your `.env` file.

> **Note:** This script requires Herd Pro for service management.

## Installation

### 1. Clone or download

Place `herd-services.sh` somewhere on your system, for example:

```bash
mkdir -p ~/bin
cp herd-services.sh ~/bin/herd-services
chmod +x ~/bin/herd-services
```

### 2. Add to your PATH

Add the following to your `~/.zshrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

Then reload your shell:

```bash
source ~/.zshrc
```

You can now run `herd-services` from any directory.

## Usage

Run the script from a directory that contains a `herd.yml` file (and optionally a `.env` file for port variables).

```
herd-services <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `start` | Stop active services, then start services defined in `herd.yml` |
| `stop`  | Stop services defined in `herd.yml` |

### Options

| Flag | Shorthand | Applies to | Description |
|------|-----------|------------|-------------|
| `--conflicts-only` | `-c` | `start` | Only stop active services that have conflicting ports with your `herd.yml` services |
| `--all` | `-a` | `stop` | Stop all active services, not just the ones in `herd.yml` |
| `--php <path>` | — | — | Path to PHP binary (default: whichever `php` is in your PATH) |
| `--help` | `-h` | — | Show usage help |

### Examples

Start your project's services (stops all active services first):

```bash
cd ~/code/my-project
herd-services start
```

Start services, only stopping ones that conflict on the same port:

```bash
herd-services start -c
```

Stop only your project's services:

```bash
herd-services stop
```

Stop every active Herd service:

```bash
herd-services stop -a
```

Use a specific PHP binary:

```bash
herd-services start --php /usr/local/bin/php8.4
```

## How it works

1. Queries Herd's MCP server to discover all currently running services
2. Parses your `herd.yml` for the services your project needs (name, version, port)
3. Resolves port variables (e.g. `${DB_PORT}`) by looking up only the referenced keys in your `.env` file
4. Stops and/or starts services via AppleScript commands to the Herd application

### Port resolution

Ports in `herd.yml` can reference environment variables:

```yaml
services:
    postgresql:
        version: '18'
        port: '${DB_PORT}'
    minio:
        version: RELEASE.2025-09-07
        port: ${AWS_ENDPOINT_PORT:-9000}
```

The script will:
- Look up `DB_PORT` in your `.env` file
- Use the bash default syntax (`:-9000`) as a fallback if `AWS_ENDPOINT_PORT` is not found
- Skip starting a service if no port can be resolved, and display a message

## Requirements

- macOS
- Laravel Herd with a Herd Pro subscription

No additional dependencies — the script uses only `bash`, `awk`, `sed`, `grep`, and `php` (bundled with Herd).

## Issues & Pull Requests
If you find any issues, feel free to raise an issue or a PR if you're not an AI bot (only humans)
