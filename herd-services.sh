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
ISOLATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    start)              MODE="start" ;;
    stop)               MODE="stop" ;;
    --conflicts-only|-c) CONFLICTS_ONLY=true ;;
    --all|-a)           ALL=true ;;
    --isolate)          ISOLATE=true ;;
    --help|-h)
      echo "Usage: $(basename "$0") <start|stop> [options]"
      echo ""
      echo "Commands:"
      echo "  start                Stop active services, then start services from herd.yml."
      echo "                       Also switches the PHP version using the 'php' field in herd.yml."
      echo "  stop                 Stop services defined in herd.yml"
      echo ""
      echo "Options:"
      echo "  -c, --conflicts-only  (start) Only stop active services with conflicting ports"
      echo "  -a, --all             (stop) Stop all active services, not just herd.yml ones"
      echo "      --isolate         (start) Use 'herd isolate <version>' instead of 'herd use <version>'"
      echo "                                to set the PHP version per-site instead of globally"
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

if ! command -v herd >/dev/null 2>&1; then
  echo ""
  echo -e "${BOLD}${CYAN}Herd Services Manager${RESET}"
  echo -e "${DIM}────────────────────────────────────${RESET}"
  echo ""
  echo -e "${RED}Error:${RESET} ${BOLD}herd${RESET} CLI not found in PATH."
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

# Parse the top-level "php" key from herd.yml (e.g. php: '8.5')
parse_herd_php_version() {
  awk '
    /^php:/ {
      v = $0
      sub(/^php:[ ]*/, "", v)
      gsub(/[\x27"\r]/, "", v)
      gsub(/[ \t]+$/, "", v)
      print v
      exit
    }
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

# Parse the JSON array from `herd services:list --json` into pipe-delimited rows.
# Output format per service: type|port|version|status|id
#
# We use FS='"' so each quoted JSON string becomes its own field. The keys and
# values alternate (key, value, key, value...) and a "},{" or "}]" in the
# separator between fields marks an object boundary. This avoids needing jq
# while still being safe against any field ordering Herd produces.
#
# Skips any non-JSON lines (e.g. PHP warnings printed before the JSON).
parse_herd_services_json() {
  awk -F'"' '
    /^\[/ {
      type=""; port=""; version=""; status=""; id=""
      pos=0; current_key=""
      for (i = 2; i <= NF; i += 2) {
        if ($(i-1) ~ /\}/) {
          if (type != "") print type "|" port "|" version "|" status "|" id
          type=""; port=""; version=""; status=""; id=""
          pos=0; current_key=""
        }
        if (pos == 0) {
          current_key = $i
          pos = 1
        } else {
          if      (current_key == "type")    type = $i
          else if (current_key == "port")    port = $i
          else if (current_key == "version") version = $i
          else if (current_key == "status")  status = $i
          else if (current_key == "id")      id = $i
          pos = 0
        }
      }
      if (type != "") print type "|" port "|" version "|" status "|" id
    }
  '
}

# Look up a service UUID from the cached Herd services data by type/version/port
get_service_id() {
  echo "$HERD_SERVICES_DATA" | awk -F'|' -v t="$1" -v v="$2" -v p="$3" '
    $1 == t && $3 == v && $2 == p { print $5; exit }
  '
}

# Extract active (running) services from cached data (output: type|port|version per line)
extract_active_services() {
  echo "$HERD_SERVICES_DATA" | awk -F'|' '$4 == "running" { print $1 "|" $2 "|" $3 }'
}

echo ""
echo -e "${BOLD}${CYAN}Herd Services Manager${RESET}"
echo -e "${DIM}────────────────────────────────────${RESET}"

if [[ "$MODE" == "start" ]]; then
  mode_flags=""
  [[ "$CONFLICTS_ONLY" == true ]] && mode_flags="conflicts only"
  if [[ "$ISOLATE" == true ]]; then
    [[ -n "$mode_flags" ]] && mode_flags+=", "
    mode_flags+="isolated PHP"
  fi
  if [[ -n "$mode_flags" ]]; then
    echo -e "${DIM}Mode: start ($mode_flags)${RESET}"
  else
    echo -e "${DIM}Mode: start${RESET}"
  fi
elif [[ "$MODE" == "stop" && "$ALL" == true ]]; then
  echo -e "${DIM}Mode: stop all${RESET}"
else
  echo -e "${DIM}Mode: stop${RESET}"
fi

echo ""

# --- Fetch current services from the herd CLI ---
echo -e "${BOLD}Fetching current Herd services...${RESET}"
# Capture stdout AND stderr together. A misconfigured php.ini may make Herd
# print Zend extension warnings before the JSON (to either stdout or stderr,
# depending on display_errors). The clean case is just a JSON line on its own.
# We use `grep -m1 '^\['` to grab the first line that starts with `[`, which
# works for both cases — with or without preceding warning lines.
herd_services_raw=$(herd services:list --json 2>&1 || true)
herd_services_json=$(echo "$herd_services_raw" | grep -m1 '^\[')

if [[ -z "$herd_services_json" ]]; then
  echo -e "${RED}Error:${RESET} failed to fetch services from ${BOLD}herd services:list --json${RESET}" >&2
  echo -e "${DIM}Service management requires a Herd Pro subscription.${RESET}" >&2
  if [[ -n "$herd_services_raw" ]]; then
    echo -e "${DIM}Output from herd command:${RESET}" >&2
    echo "$herd_services_raw" | sed 's/^/  /' >&2
  fi
  exit 1
fi

HERD_SERVICES_DATA=$(echo "$herd_services_json" | parse_herd_services_json)

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

  # --- Switch PHP version (if defined in herd.yml) ---
  php_version=$(parse_herd_php_version)
  if [[ -n "$php_version" ]]; then
    echo ""
    if [[ "$ISOLATE" == true ]]; then
      echo -e "${BOLD}Isolating PHP version${RESET}"
    else
      echo -e "${BOLD}Setting PHP version${RESET}"
    fi
    echo -e "${DIM}────────────────────────────────────${RESET}"

    php_label=$(printf "%-15s" "php")
    if [[ "$ISOLATE" == true ]]; then
      if herd_err=$(herd isolate "$php_version" 2>&1 >/dev/null); then
        echo -e "  ${php_label} ${DIM}version:${RESET} $php_version ${GREEN}isolated${RESET} ${DIM}(per-site)${RESET}"
      else
        echo -e "  ${php_label} ${DIM}version:${RESET} $php_version ${YELLOW}warning${RESET} ${DIM}(failed to isolate)${RESET}"
        [[ -n "$herd_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$herd_err" | head -n 1)${RESET}"
        fail_count=$((fail_count + 1))
      fi
    else
      if herd_err=$(herd use "$php_version" 2>&1 >/dev/null); then
        echo -e "  ${php_label} ${DIM}version:${RESET} $php_version ${GREEN}set${RESET} ${DIM}(global default)${RESET}"
      else
        echo -e "  ${php_label} ${DIM}version:${RESET} $php_version ${YELLOW}warning${RESET} ${DIM}(failed to set)${RESET}"
        [[ -n "$herd_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$herd_err" | head -n 1)${RESET}"
        fail_count=$((fail_count + 1))
      fi
    fi
  fi

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

    svc_id=$(get_service_id "$svc_type" "$svc_version" "$svc_port")
    if [[ -z "$svc_id" ]]; then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}skipped${RESET} ${DIM}(not found in Herd services registry)${RESET}"
      skip_count=$((skip_count + 1)); continue
    fi
    if osascript_err=$(osascript -e 'tell application "Herd" to stop extraservice "'"$svc_id"'"' 2>&1 >/dev/null); then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
    else
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
      [[ -n "$osascript_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$osascript_err" | sed 's/^[0-9]*:[0-9]*: //')${RESET}"
      fail_count=$((fail_count + 1))
    fi
    stop_count=$((stop_count + 1))
  done < <(extract_active_services)

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

    svc_id=$(get_service_id "$svc_name" "$svc_version" "$svc_port")
    if [[ -z "$svc_id" ]]; then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}skipped${RESET} ${DIM}(not found in Herd services registry)${RESET}"
      skip_count=$((skip_count + 1)); continue
    fi
    if osascript_err=$(osascript -e 'tell application "Herd" to start extraservice "'"$svc_id"'"' 2>&1 >/dev/null); then
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${GREEN}started${RESET}"
    else
      echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to start)${RESET}"
      [[ -n "$osascript_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$osascript_err" | sed 's/^[0-9]*:[0-9]*: //')${RESET}"
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

      svc_id=$(get_service_id "$svc_type" "$svc_version" "$svc_port")
      if [[ -z "$svc_id" ]]; then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}skipped${RESET} ${DIM}(not found in Herd services registry)${RESET}"
        skip_count=$((skip_count + 1)); continue
      fi
      if osascript_err=$(osascript -e 'tell application "Herd" to stop extraservice "'"$svc_id"'"' 2>&1 >/dev/null); then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
      else
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
        [[ -n "$osascript_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$osascript_err" | sed 's/^[0-9]*:[0-9]*: //')${RESET}"
        fail_count=$((fail_count + 1))
      fi
      stop_count=$((stop_count + 1))
    done < <(extract_active_services)

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

      svc_id=$(get_service_id "$svc_name" "$svc_version" "$svc_port")
      if [[ -z "$svc_id" ]]; then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}skipped${RESET} ${DIM}(not found in Herd services registry)${RESET}"
        skip_count=$((skip_count + 1)); continue
      fi
      if osascript_err=$(osascript -e 'tell application "Herd" to stop extraservice "'"$svc_id"'"' 2>&1 >/dev/null); then
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${RED}stopped${RESET}"
      else
        echo -e "  ${svc_label} ${DIM}port:${RESET} $svc_port ${DIM}version:${RESET} $svc_version ${YELLOW}warning${RESET} ${DIM}(failed to stop)${RESET}"
        [[ -n "$osascript_err" ]] && echo -e "    ${RED}${DIM}↳ $(echo "$osascript_err" | sed 's/^[0-9]*:[0-9]*: //')${RESET}"
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
echo ""
