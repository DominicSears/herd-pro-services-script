# Herd Services Manager

A bash script to manage Laravel Herd services from the command line. It reads your project's `herd.yml` to start and stop services (resolving ports from your `.env` file) and switches the PHP version to whatever your project declares.

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
| `start` | Switch to the PHP version in `herd.yml`, stop active services, then start the services defined in `herd.yml` |
| `stop`  | Stop services defined in `herd.yml` |

### Options

| Flag | Shorthand | Applies to | Description |
|------|-----------|------------|-------------|
| `--conflicts-only` | `-c` | `start` | Only stop active services that have conflicting ports with your `herd.yml` services |
| `--all` | `-a` | `stop` | Stop all active services, not just the ones in `herd.yml` |
| `--isolate` | — | `start` | Set the PHP version per-site using `herd isolate <version>` instead of the global `herd use <version>` |
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

Isolate the PHP version for the current site (per-site instead of global):

```bash
herd-services start --isolate
```

## How it works

1. Reads your `herd.yml` for the services your project needs (name, version, port) and the `php:` field for the PHP version
2. Calls `herd services:list --json` once to get every Herd service with its current `status` (`running`/`stopped`) and internal UUID
3. Resolves port variables (e.g. `${DB_PORT}`) by looking up only the referenced keys in your `.env` file
4. (`start` only) Switches the PHP version with `herd use <version>` (or `herd isolate <version>` with `--isolate`)
5. Stops and/or starts services by UUID via AppleScript commands to the Herd application

### Service ID resolution

The script gets every service's UUID directly from `herd services:list --json`. Each `herd.yml` service is matched against that list by `type`, `version`, and `port` to find the corresponding UUID — this is necessary because multiple instances of the same service type can exist (e.g. MySQL 8 on port 3306 and MySQL 9 on port 3307). The UUID is then passed to the AppleScript API:

```
tell application "Herd" to start extraservice "UUID"
```

If a specific service from your `herd.yml` has no matching entry in Herd's services list, it is skipped with a warning.

### PHP version switching

If your `herd.yml` has a top-level `php:` key, `herd-services start` will run `herd use <version>` to set the global PHP version before starting services. With `--isolate`, it runs `herd isolate <version>` instead, which sets the PHP version for the current site only.

```yaml
name: my-project
php: '8.5'
services:
    ...
```

If `php:` is not present in `herd.yml`, the PHP version step is skipped.

### Handling misconfigured `php.ini`

`herd services:list --json` may print PHP warnings (e.g. *"...doesn't appear to be a valid Zend extension"*) before the JSON if your `php.ini` has issues. The script captures both stdout and stderr and grabs the first line that starts with `[`, so it works whether or not those warnings are present.

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
- Laravel Herd with a Herd Pro subscription (the `herd` CLI must be in your `PATH`)

No additional dependencies — the script uses only `bash`, `awk`, `sed`, and `grep`.

## Issues & Pull Requests
If you find any issues, feel free to raise an issue or a PR if you're not an AI bot (only humans)
