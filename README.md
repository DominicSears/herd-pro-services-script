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
4. Looks up each service's internal UUID from Herd's `services.plist` registry
5. Stops and/or starts services by UUID via AppleScript commands to the Herd application

### Service ID resolution

This script uses your services.plist to find the service ID for running the correct services in the `herd.yml` file

Specifically the one located here:

```
~/Library/Application Support/Herd/config/services.plist
```

It matches each service by `type`, `version`, and `port` to find the corresponding UUID — this is necessary because multiple instances of the same service type can exist (e.g. MySQL 8 on port 3306 and MySQL 9 on port 3307). The UUID is then passed to the AppleScript API:

```
tell application "Herd" to start extraservice "UUID"
```

If the plist is not present, the script exits early with an error — this file is only created for Herd Pro subscribers. If a specific service from your `herd.yml` has no matching entry in the plist, it is skipped with a warning.

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
- Look up any enviornment file key references from your `herd.yml` file to your `.env` file (it only searches keys first and then only the values of matching keys that are referenced)
- Use the bash default syntax (`:-9000`) as a fallback if the enviornment reference key isn't found
- Skip starting a service if no port can be resolved, and display a message

## Requirements

- macOS
- Laravel Herd with a Herd Pro subscription

No additional dependencies — the script uses only `bash`, `awk`, `sed`, `grep`, and `php` (bundled with Herd).

## Issues & Pull Requests
If you find any issues, feel free to raise an issue or a PR if you're not an AI bot (only humans)
