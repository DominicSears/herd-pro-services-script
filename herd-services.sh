#!/bin/bash

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

MODE=""
CONFLICTS_ONLY=false
ALL=false
PHP_BIN="php"

while [[ $# -gt 0 ]]; do
  case "$1" in
    start)              MODE="start" ;;
    stop)               MODE="stop" ;;
    --conflicts-only|-c) CONFLICTS_ONLY=true ;;
    --all|-a)           ALL=true ;;
    --php)              PHP_BIN="$2"; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") <start|stop> [options]"
      echo ""
      echo "Commands:"
      echo "  start                Stop active services, then start services from herd.yml"
      echo "  stop                 Stop services defined in herd.yml"
      echo ""
      echo "Options:"
      echo "  -c, --conflicts-only  (start) Only stop active services with conflicting ports"
      echo "  -a, --all             (stop) Stop all active services, not just herd.yml ones"
      echo "      --php <path>      Path to PHP binary (default: php)"
      echo "  -h, --help            Show this help"
      exit 0
      ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  echo -e "${RED}Error:${RESET} missing command. Use ${BOLD}start${RESET} or ${BOLD}stop${RESET}"
  echo -e "${DIM}Run with --help for usage${RESET}"
  exit 1
fi

WORK_DIR="$(pwd)"
HERD_YML="$WORK_DIR/herd.yml"
HERD_MCP="/Applications/Herd.app/Contents/Resources/herd-mcp.phar"

if [[ ! -f "$HERD_YML" ]]; then
  echo ""
  echo -e "${BOLD}${CYAN}Herd Services Manager${RESET}"
  echo -e "${DIM}────────────────────────────────────${RESET}"
  echo ""
  echo -e "${RED}Error:${RESET} herd.yml not found in ${BOLD}$WORK_DIR${RESET}"
  echo -e "${DIM}Make sure you're running this from a directory with a herd.yml file.${RESET}"
  echo -e "${DIM}This file is created by Laravel Herd when you configure services for a project.${RESET}"
  echo ""
  exit 1
fi

# Parse services from herd.yml (output: name|version|port_raw per line)
parse_herd_services() {
  awk '
    /^services:/ { in_services=1; next }
    in_services && /^[^ ]/ {
      if (svc != "" && ver != "" && port != "") print svc "|" ver "|" port
      svc = ""; ver = ""; port = ""
      exit
    }
    in_services && /^    [a-zA-Z]/ {
      if (svc != "" && ver != "" && port != "") print svc "|" ver "|" port
      s = $0; gsub(/^[ ]+/, "", s); gsub(/:.*/, "", s)
      svc = s; ver = ""; port = ""
    }
    in_services && /^        version:/ {
      v = $0; sub(/^.*version:[ ]*/, "", v); gsub(/[\x27"\r]/, "", v); gsub(/[ \t]+$/, "", v)
      ver = v
    }
    in_services && /^        port:/ {
      p = $0; sub(/^.*port:[ ]*/, "", p); gsub(/[\x27"\r]/, "", p); gsub(/[ \t]+$/, "", p)
      port = p
    }
    END { if (svc != "" && ver != "" && port != "") print svc "|" ver "|" port }
  ' "$HERD_YML"
}

# Load only the env vars referenced in herd.yml port values from .env
load_port_env_vars() {
  local env_file="$WORK_DIR/.env"
  [[ ! -f "$env_file" ]] && return

  while IFS='|' read -r _ _ port_raw; do
    local remaining="$port_raw"
    while [[ "$remaining" =~ \$\{([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
      local var_name="${BASH_REMATCH[1]}"
      if [[ -z "${!var_name+x}" ]]; then
        local val
        val=$(grep -m1 "^${var_name}=" "$env_file" | cut -d= -f2-) || true
        if [[ -n "$val" ]]; then
          export "$var_name=$val"
        fi
      fi
      remaining="${remaining#*"${BASH_REMATCH[0]}"}"
    done
  done < <(parse_herd_services)
}

# Build list of resolved ports from herd.yml
build_herd_ports() {
  while IFS='|' read -r _ _ port_raw; do
    local resolved
    resolved=$(eval echo "$port_raw")
    [[ -n "$resolved" ]] && echo "$resolved"
  done < <(parse_herd_services)
}

# Extract active services from MCP JSON (output: type|port|version per line)
# Uses awk with quote-delimited fields to scan for known key patterns.
# Parent service "type" values are lowercase (redis, minio), while installed
# service "type" values are capitalized (Redis, MinIO), so we distinguish them.
extract_active_services() {
  echo "$1" | awk -F'"' '{
    parent_type = ""
    in_installed = 0
    is_port = ""; is_version = ""; is_active = 0

    for (i = 1; i <= NF; i++) {
      if ($i == "label" && $(i+1) ~ /^:/) in_installed = 0

      if ($i == "installedServices") {
        in_installed = 1
        is_port = ""; is_version = ""; is_active = 0
      }

      if ($i == "type" && $(i+1) ~ /^:/) {
        val = $(i+2)
        if (val ~ /^[a-z]/) {
          if (is_active && parent_type != "" && is_port != "" && is_version != "") {
            print parent_type "|" is_port "|" is_version
          }
          parent_type = val
          in_installed = 0
          is_port = ""; is_version = ""; is_active = 0
        }
      }

      if (in_installed) {
        if ($i == "status" && $(i+1) ~ /^:/ && $(i+2) == "active") is_active = 1
        if ($i == "port" && $(i+1) ~ /^:/) is_port = $(i+2)
        if ($i == "version" && $(i+1) ~ /^:/) is_version = $(i+2)
      }
    }

    if (is_active && parent_type != "" && is_port != "" && is_version != "") {
      print parent_type "|" is_port "|" is_version
    }
  }'
}

echo ""
echo -e "${BOLD}${CYAN}Herd Services Manager${RESET}"
echo -e "${DIM}────────────────────────────────────${RESET}"

if [[ "$MODE" == "start" && "$CONFLICTS_ONLY" == true ]]; then
  echo -e "${DIM}Mode: start (conflicts only)${RESET}"
elif [[ "$MODE" == "start" ]]; then
  echo -e "${DIM}Mode: start${RESET}"
elif [[ "$MODE" == "stop" && "$ALL" == true ]]; then
  echo -e "${DIM}Mode: stop all${RESET}"
else
  echo -e "${DIM}Mode: stop${RESET}"
fi

echo ""

# --- Fetch current services from Herd MCP ---
echo -e "${BOLD}Fetching current Herd services...${RESET}"
mcp_raw=$(
  printf '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"find_available_services","arguments":{}},"id":1}\n{"jsonrpc":"2.0","method":"exit"}\n' \
    | "$PHP_BIN" "$HERD_MCP" 2>/dev/null || true
)

# Extract the text field from MCP JSON response and unescape
services_json=$(echo "$mcp_raw" | head -n 1 | sed 's/.*"text":"//; s/"}],"isError".*//' | sed 's/\\"/"/g; s/\\\//\//g')

if [[ -z "$services_json" ]]; then
  echo -e "${RED}Error:${RESET} failed to fetch services from Herd MCP" >&2
  exit 1
fi

# Resolve herd.yml ports
load_port_env_vars
herd_ports=$(build_herd_ports)

# Check if herd.yml has any services defined
herd_service_count=$(parse_herd_services | wc -l | tr -d ' ')
if [[ "$herd_service_count" -eq 0 && ("$MODE" == "start" || ("$MODE" == "stop" && "$ALL" == false)) ]]; then
  echo ""
  echo -e "${YELLOW}No services found in herd.yml${RESET}"
  echo -e "${DIM}Add services to your herd.yml to manage them with this script.${RESET}"
  echo -e "${DIM}Example:${RESET}"
  echo -e "${DIM}  services:${RESET}"
  echo -e "${DIM}    redis:${RESET}"
  echo -e "${DIM}      version: 7.4.7${RESET}"
  echo -e "${DIM}      port: 6379${RESET}"
  echo ""
  exit 0
fi

stop_count=0
start_count=0
skip_count=0
fail_count=0
kept_count=0
kept_services=""

# =============================================================================
# MODE: start
# =============================================================================
if [[ "$MODE" == "start" ]]; then

  # --- Stop active services ---
  echo ""
  if [[ "$CONFLICTS_ONLY" == true ]]; then
    echo -e "${BOLD}Stopping conflicting services${RESET}"
  else
    echo -e "${BOLD}Stopping active services${RESET}"
  fi
  echo -e "${DIM}────────────────────────────────────${RESET}"

  while IFS='|' read -r svc_type svc_port svc_version; do
    [[ -z "$svc_type" ]] && continue
    svc_label=$(printf "%-15s" "$svc_type")

    if [[ "$CONFLICTS_ONLY" == true ]] && ! echo "$herd_ports" | grep -qx "$svc_port"; then
      kept_services+="  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${CYAN}running${RESET}\n"
      kept_count=$((kept_count + 1))
      continue
    fi

    if osascript -e 'tell application "Herd" to stop extraservice "'"$svc_type"'" port "'"$svc_port"'" version "'"$svc_version"'"' >/dev/null 2>&1; then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
    else
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
      fail_count=$((fail_count + 1))
    fi
    stop_count=$((stop_count + 1))
  done < <(extract_active_services "$services_json")

  if [[ $stop_count -eq 0 && $kept_count -eq 0 ]]; then
    echo -e "  ${DIM}No active services to stop${RESET}"
  fi

  if [[ -n "$kept_services" ]]; then
    echo ""
    echo -e "${BOLD}Still running${RESET} ${DIM}(no port conflict)${RESET}"
    echo -e "${DIM}────────────────────────────────────${RESET}"
    echo -ne "$kept_services"
  fi

  # --- Start services from herd.yml ---
  echo ""
  echo -e "${BOLD}Starting services from herd.yml${RESET}"
  echo -e "${DIM}────────────────────────────────────${RESET}"

  while IFS='|' read -r svc_name svc_version svc_port_raw; do
    [[ -z "$svc_name" ]] && continue

    svc_port=$(eval echo "$svc_port_raw")
    svc_label=$(printf "%-15s" "$svc_name")

    if [[ -z "$svc_port" ]]; then
      echo -e "  ${svc_label} ${YELLOW}not started${RESET} ${DIM}(no default or .env value found for port)${RESET}"
      skip_count=$((skip_count + 1))
      continue
    fi

    if osascript -e 'tell application "Herd" to start extraservice "'"$svc_name"'" port "'"$svc_port"'" version "'"$svc_version"'"' >/dev/null 2>&1; then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${GREEN}started${RESET}"
    else
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to start)${RESET}"
      fail_count=$((fail_count + 1))
    fi
    start_count=$((start_count + 1))
  done < <(parse_herd_services)

# =============================================================================
# MODE: stop
# =============================================================================
elif [[ "$MODE" == "stop" ]]; then

  if [[ "$ALL" == true ]]; then
    # --- Stop all active services ---
    echo ""
    echo -e "${BOLD}Stopping all active services${RESET}"
    echo -e "${DIM}────────────────────────────────────${RESET}"

    while IFS='|' read -r svc_type svc_port svc_version; do
      [[ -z "$svc_type" ]] && continue
      svc_label=$(printf "%-15s" "$svc_type")

      if osascript -e 'tell application "Herd" to stop extraservice "'"$svc_type"'" port "'"$svc_port"'" version "'"$svc_version"'"' >/dev/null 2>&1; then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
      else
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
        fail_count=$((fail_count + 1))
      fi
      stop_count=$((stop_count + 1))
    done < <(extract_active_services "$services_json")

    if [[ $stop_count -eq 0 ]]; then
      echo -e "  ${DIM}No active services to stop${RESET}"
    fi

  else
    # --- Stop only services from herd.yml ---
    echo ""
    echo -e "${BOLD}Stopping services from herd.yml${RESET}"
    echo -e "${DIM}────────────────────────────────────${RESET}"

    while IFS='|' read -r svc_name svc_version svc_port_raw; do
      [[ -z "$svc_name" ]] && continue

      svc_port=$(eval echo "$svc_port_raw")
      svc_label=$(printf "%-15s" "$svc_name")

      if [[ -z "$svc_port" ]]; then
        echo -e "  ${svc_label} ${YELLOW}not stopped${RESET} ${DIM}(no default or .env value found for port)${RESET}"
        skip_count=$((skip_count + 1))
        continue
      fi

      if osascript -e 'tell application "Herd" to stop extraservice "'"$svc_name"'" port "'"$svc_port"'" version "'"$svc_version"'"' >/dev/null 2>&1; then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
      else
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
        fail_count=$((fail_count + 1))
      fi
      stop_count=$((stop_count + 1))
    done < <(parse_herd_services)
  fi
fi

# --- Summary ---
echo ""
echo -e "${DIM}────────────────────────────────────${RESET}"
summary="${BOLD}Summary:${RESET} ${RED}$stop_count stopped${RESET}"
if [[ "$MODE" == "start" ]]; then
  summary+=" | ${GREEN}$start_count started${RESET}"
fi
if [[ $skip_count -gt 0 ]]; then
  summary+=" | ${YELLOW}$skip_count skipped${RESET}"
fi
if [[ $kept_count -gt 0 ]]; then
  summary+=" | ${CYAN}$kept_count kept running${RESET}"
fi
echo -e "$summary"

# Check if all commands failed (likely no Herd Pro)
total_attempted=$((stop_count + start_count - skip_count))
if [[ $total_attempted -gt 0 && $fail_count -eq $total_attempted ]]; then
  echo ""
  echo -e "${RED}All service commands failed.${RESET}"
  echo -e "${DIM}This typically means Herd Pro is not active. Services require a Herd Pro subscription.${RESET}"
  echo -e "${DIM}Herd Pro is required for service management.${RESET}"
fi
echo ""
