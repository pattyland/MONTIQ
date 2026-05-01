#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/montiq.conf}"
DEBUG=false

if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=true
  shift
fi

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

debug() {
  if [[ "$DEBUG" == true ]]; then
    log "DEBUG: $*"
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

print_banner() {
  cat <<'EOF'
███    ███  ██████  ███    ██ ████████ ██  ██████  
████  ████ ██    ██ ████   ██    ██    ██ ██    ██ 
██ ████ ██ ██    ██ ██ ██  ██    ██    ██ ██    ██ 
██  ██  ██ ██    ██ ██  ██ ██    ██    ██ ██ ▄▄ ██ 
██      ██  ██████  ██   ████    ██    ██  ██████  
        Monitoring Telemetry In Queue        ▀▀    
EOF
}

detect_hostname() {
  local hn=""
  if command -v hostname >/dev/null 2>&1; then
    hn=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
  fi
  [[ -n "$hn" ]] || hn="edge-device"
  printf '%s' "$hn"
}

detect_model() {
  local path model
  for path in /sys/firmware/devicetree/base/model /proc/device-tree/model; do
    if [[ -r "$path" ]]; then
      tr -d '\0' <"$path"
      return 0
    fi
  done
  if command -v sysctl >/dev/null 2>&1; then
    model=$(sysctl -n hw.model 2>/dev/null || true)
    if [[ -n "$model" ]]; then
      printf '%s' "$model"
      return 0
    fi
  fi
  return 1
}

detect_disk_path() {
  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" && -d /System/Volumes/Data ]]; then
    printf '%s' "/System/Volumes/Data"
  else
    printf '%s' "/"
  fi
}

sanitize_id() {
  local input=$1
  input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  input=$(printf '%s' "$input" | tr -c 'a-z0-9_.-' '_')
  input=${input//__/_}
  input=${input##_}
  input=${input%%_}
  printf '%s' "$input"
}

[[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"
debug "Using config file: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

DEFAULT_HOSTNAME=$(detect_hostname)
DEFAULT_NODE_ID=$(sanitize_id "$DEFAULT_HOSTNAME")
[[ -n "$DEFAULT_NODE_ID" ]] || DEFAULT_NODE_ID=$(sanitize_id "edge-device")
DEFAULT_DEVICE_MODEL=$(detect_model || true)
[[ -n "$DEFAULT_DEVICE_MODEL" ]] || DEFAULT_DEVICE_MODEL="Unknown Model"

MQTT_HOST=${MQTT_HOST:-}
MQTT_PORT=${MQTT_PORT:-1883}
MQTT_USERNAME=${MQTT_USERNAME:-}
MQTT_PASSWORD=${MQTT_PASSWORD:-}
MQTT_CLIENT_ID=${MQTT_CLIENT_ID:-}
MQTT_USE_TLS=${MQTT_USE_TLS:-false}
MQTT_CA_FILE=${MQTT_CA_FILE:-}
MQTT_CERT_FILE=${MQTT_CERT_FILE:-}
MQTT_KEY_FILE=${MQTT_KEY_FILE:-}
DISCOVERY_PREFIX=${DISCOVERY_PREFIX:-homeassistant}
NODE_ID=$(sanitize_id "${NODE_ID:-$DEFAULT_NODE_ID}")
[[ -n "$NODE_ID" ]] || fail "NODE_ID must contain at least one letter or number after sanitizing"
MQTT_CLIENT_ID=${MQTT_CLIENT_ID:-montiq-${NODE_ID}}
STATE_BASE_PREFIX=${STATE_BASE_PREFIX:-$DISCOVERY_PREFIX}
DEVICE_MODEL=${DEVICE_MODEL:-$DEFAULT_DEVICE_MODEL}
RETAIN_DISCOVERY_MESSAGES=${RETAIN_DISCOVERY_MESSAGES:-true}
MOSQUITTO_PUB_BIN=${MOSQUITTO_PUB_BIN:-mosquitto_pub}
ENABLE_CPU_SENSOR=${ENABLE_CPU_SENSOR:-true}
ENABLE_VOLTAGE_SENSOR=${ENABLE_VOLTAGE_SENSOR:-true}
ENABLE_LOAD_SENSOR=${ENABLE_LOAD_SENSOR:-true}
ENABLE_UPTIME_SENSOR=${ENABLE_UPTIME_SENSOR:-true}
ENABLE_MEMORY_SENSOR=${ENABLE_MEMORY_SENSOR:-true}
ENABLE_DISK_SENSOR=${ENABLE_DISK_SENSOR:-true}
DISK_PATH=${DISK_PATH:-$(detect_disk_path)}

[[ -n "$MQTT_HOST" ]] || fail "MQTT_HOST must be set in $CONFIG_FILE"
if ! command -v "$MOSQUITTO_PUB_BIN" >/dev/null 2>&1; then
  fail "mosquitto_pub binary not found (set MOSQUITTO_PUB_BIN in config if needed)"
fi

json_escape() {
  local input=$1
  input=${input//\\/\\\\}
  input=${input//\"/\\\"}
  printf '%s' "$input"
}

is_true() {
  case "$1" in
    true|TRUE|True|1|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

build_mqtt_args() {
  MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT" -i "$MQTT_CLIENT_ID")
  if [[ -n "$MQTT_USERNAME" ]]; then
    MQTT_ARGS+=(-u "$MQTT_USERNAME")
  fi
  if [[ -n "$MQTT_PASSWORD" ]]; then
    MQTT_ARGS+=(-P "$MQTT_PASSWORD")
  fi
  if is_true "$MQTT_USE_TLS"; then
    MQTT_ARGS+=(--tls-version tlsv1.2)
    [[ -n "$MQTT_CA_FILE" ]] && MQTT_ARGS+=(--cafile "$MQTT_CA_FILE")
    [[ -n "$MQTT_CERT_FILE" ]] && MQTT_ARGS+=(--cert "$MQTT_CERT_FILE")
    [[ -n "$MQTT_KEY_FILE" ]] && MQTT_ARGS+=(--key "$MQTT_KEY_FILE")
  fi
}

publish() {
  local topic=$1
  local payload=$2
  local retain_flag=${3:-false}
  local args
  build_mqtt_args
  args=("${MQTT_ARGS[@]}")
  args+=(-t "$topic" -m "$payload")
  if is_true "$retain_flag"; then
    args+=(-r)
  fi
  if "$MOSQUITTO_PUB_BIN" "${args[@]}"; then
    debug "Published topic='$topic' retain=${retain_flag}"
  else
    fail "Failed to publish topic '$topic' via MQTT"
  fi
}

read_cpu_temp() {
  local temp
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    temp=$(< /sys/class/thermal/thermal_zone0/temp)
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      awk -v raw="$temp" 'BEGIN { printf "%.1f", raw / 1000 }'
      return 0
    fi
  fi
  if command -v vcgencmd >/dev/null 2>&1; then
    temp=$(vcgencmd measure_temp 2>/dev/null | tr -cd '0-9.\n')
    if [[ -n "$temp" ]]; then
      printf '%s' "$temp"
      return 0
    fi
  fi
  return 1
}

read_voltage_alarm() {
  local result
  if command -v vcgencmd >/dev/null 2>&1; then
    result=$(vcgencmd get_throttled 2>/dev/null | awk -F'=' '/throttled/ { print $2 }')
    if [[ "$result" =~ ^0x[0-9a-fA-F]+$ ]]; then
      local value=$((result))
      if (( value & 0x1 )); then
        printf '1'
      else
        printf '0'
      fi
      return 0
    fi
  fi
  return 1
}

read_load_averages() {
  if [[ -r /proc/loadavg ]]; then
    awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg
    return 0
  fi
  if command -v uptime >/dev/null 2>&1; then
    local values first second third
    values=$(uptime 2>/dev/null | awk -F'load averages?:' '
      function normalize(value) {
        sub(/,$/, "", value)
        gsub(/,/, ".", value)
        return value
      }
      NF > 1 {
        n = split($2, raw, /[[:space:]]+/)
        for (i = 1; i <= n && count < 3; i++) {
          value = normalize(raw[i])
          if (value ~ /^[0-9]+([.][0-9]+)?$/) {
            load[++count] = value
          }
        }
        if (count == 3) {
          print load[1], load[2], load[3]
        }
      }
    ')
    read -r first second third _ <<<"$values"
    if [[ -n "$first" && -n "$second" && -n "$third" ]]; then
      printf '%s %s %s' "$first" "$second" "$third"
      return 0
    fi
  fi
  return 1
}

read_disk_usage_percent() {
  if command -v df >/dev/null 2>&1; then
    local percent
    percent=$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')
    if [[ "$percent" =~ ^[0-9]+$ ]]; then
      printf '%s' "$percent"
      return 0
    fi
  fi
  return 1
}

format_timestamp() {
  local epoch=$1
  if command -v date >/dev/null 2>&1; then
    if date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
      date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
      return 0
    elif date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
      date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
      return 0
    fi
  fi
  printf '%s' "$epoch"
}

read_last_boot_timestamp() {
  local seconds
  if [[ -r /proc/uptime ]]; then
    seconds=$(awk '{ printf "%d", $1 }' /proc/uptime)
  fi
  if [[ -n "${seconds:-}" ]]; then
    local now epoch
    now=$(date +%s)
    epoch=$((now - seconds))
    format_timestamp "$epoch"
    return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    local boot_epoch
    boot_epoch=$(sysctl kern.boottime 2>/dev/null | awk -F'[=,]' '/sec =/ { gsub(/[^0-9]/, "", $2); print $2 }')
    if [[ "$boot_epoch" =~ ^[0-9]+$ ]]; then
      format_timestamp "$boot_epoch"
      return 0
    fi
  fi
  return 1
}

read_memory_usage_percent() {
  if [[ -r /proc/meminfo ]]; then
    local total free available percent
    while read -r key value _; do
      case $key in
        MemTotal:) total=$value ;;
        MemAvailable:) available=$value ;;
      esac
    done < /proc/meminfo
    if [[ -n "$total" && -n "$available" && "$total" -gt 0 ]]; then
      free=$available
      percent=$(awk -v t="$total" -v f="$free" 'BEGIN { printf "%.2f", (t - f) / t * 100 }')
      printf '%s' "$percent"
      return 0
    fi
  fi
  if command -v vm_stat >/dev/null 2>&1; then
    local percent
    percent=$(vm_stat 2>/dev/null | awk '
      function clean(value) {
        gsub(/[^0-9]/, "", value)
        return value + 0
      }
      NR == 1 {
        page_size = clean($0)
      }
      $1 == "Pages" && $2 == "free:" { free = clean($3) }
      $1 == "Pages" && $2 == "active:" { active = clean($3) }
      $1 == "Pages" && $2 == "inactive:" { inactive = clean($3) }
      $1 == "Pages" && $2 == "speculative:" { speculative = clean($3) }
      $1 == "Pages" && $2 == "wired" && $3 == "down:" { wired = clean($4) }
      $1 == "Pages" && $2 == "occupied" && $3 == "by" && $4 == "compressor:" { compressor = clean($5) }
      END {
        total = free + active + inactive + speculative + wired + compressor
        used = total - free - speculative
        if (page_size > 0 && total > 0 && used >= 0) {
          printf "%.2f", used / total * 100
        }
      }
    ')
    if [[ "$percent" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      printf '%s' "$percent"
      return 0
    fi
  fi
  return 1
}

device_json=$(cat <<EOF
{"identifiers":["$(json_escape "$NODE_ID")"],"name":"$(json_escape "$DEFAULT_HOSTNAME")","model":"$(json_escape "$DEVICE_MODEL")"}
EOF
)

publish_config() {
  local entity_type=$1
  local suffix=$2
  local name=$3
  local extra_json=${4:-}
  local unique_id="${NODE_ID}_${suffix}"
  local state_topic="${STATE_BASE_PREFIX}/${entity_type}/${unique_id}"
  local payload
  payload=$(cat <<EOF
{"~":"$(json_escape "$state_topic")","name":"$(json_escape "$name")","unique_id":"${unique_id}","default_entity_id":"${entity_type}.${unique_id}","state_topic":"~","expire_after":360${extra_json},"device":$device_json}
EOF
)
  publish "$DISCOVERY_PREFIX/${entity_type}/${unique_id}/config" "$payload" "$RETAIN_DISCOVERY_MESSAGES"
  PUBLISHED_STATE_TOPIC=$state_topic
}

publish_state() {
  local label=$1
  local entity_type=$2
  local suffix=$3
  local name=$4
  local extra_json=$5
  local value=$6
  local unavailable_message=$7
  local topic
  if [[ -z "$value" ]]; then
    debug "WARN: ${unavailable_message}; skipping discovery/state publish"
    return 0
  fi
  publish_config "$entity_type" "$suffix" "$name" "$extra_json"
  topic=$PUBLISHED_STATE_TOPIC
  publish "$topic" "$value"
  debug "[MQTT] ${label} published to $topic"
}

main() {
  if [[ "$DEBUG" == true ]]; then
    print_banner
    debug "=== System Info ==="
    debug "Hostname: $DEFAULT_HOSTNAME"
    debug "Node ID: $NODE_ID"
    debug "Device model: $DEVICE_MODEL"
    debug "Disk path: $DISK_PATH"
    local cron_matches
    cron_matches=$(crontab -l 2>/dev/null | grep -F "$(basename "$0")" || true)
    if [[ -z "$cron_matches" ]]; then
      log "WARN: No cronjob found for $(basename "$0"). Add one via 'crontab -e'."
    else
      debug "Cron entries detected:"
      printf '%s\n' "$cron_matches"
    fi
  fi

  if is_true "$ENABLE_CPU_SENSOR"; then
    local cpu_temp
    cpu_temp="$(read_cpu_temp || true)"
    [[ -n "$cpu_temp" ]] && debug "[Sensors] CPU temperature read: $cpu_temp"
    publish_state "CPU temperature" "sensor" "cpu_temperature" "CPU Temperature" ',"unit_of_measurement":"°C","device_class":"temperature","state_class":"measurement"' "$cpu_temp" "CPU temperature unavailable"
  fi

  if is_true "$ENABLE_VOLTAGE_SENSOR"; then
    local voltage_alarm
    voltage_alarm="$(read_voltage_alarm || true)"
    [[ -n "$voltage_alarm" ]] && debug "[Sensors] Undervoltage flag read: $voltage_alarm"
    publish_state "Undervoltage flag" "binary_sensor" "undervoltage" "Undervoltage" ',"device_class":"problem","payload_on":"1","payload_off":"0","entity_category":"diagnostic","icon":"mdi:flash-alert"' "$voltage_alarm" "Undervoltage status unavailable"
  fi

  if is_true "$ENABLE_LOAD_SENSOR"; then
    local load_values
    load_values="$(read_load_averages || true)"
    [[ -n "$load_values" ]] && debug "[Sensors] Load averages read: $load_values"
    if [[ -n "$load_values" ]]; then
      local load_1
      read -r load_1 _ <<<"$load_values"
      publish_state "Load average" "sensor" "load_1m" "Load 1m" ',"state_class":"measurement","icon":"mdi:cpu-64-bit"' "$load_1" "Load averages unavailable"
    else
      debug "WARN: Load averages unavailable; skipping discovery/state publish"
    fi
  fi

  if is_true "$ENABLE_UPTIME_SENSOR"; then
    local last_boot
    last_boot="$(read_last_boot_timestamp || true)"
    [[ -n "$last_boot" ]] && debug "[Sensors] Last boot timestamp read: $last_boot"
    publish_state "Last boot timestamp" "sensor" "uptime" "Last Boot" ',"device_class":"timestamp"' "$last_boot" "Last boot timestamp unavailable"
  fi

  if is_true "$ENABLE_MEMORY_SENSOR"; then
    local mem_usage
    mem_usage="$(read_memory_usage_percent || true)"
    [[ -n "$mem_usage" ]] && debug "[Sensors] Memory usage read: $mem_usage%"
    publish_state "Memory usage" "sensor" "memory_usage" "Memory Usage" ',"unit_of_measurement":"%","state_class":"measurement","icon":"mdi:memory"' "$mem_usage" "Memory usage unavailable"
  fi

  if is_true "$ENABLE_DISK_SENSOR"; then
    local disk_usage
    disk_usage="$(read_disk_usage_percent || true)"
    [[ -n "$disk_usage" ]] && debug "[Sensors] Disk usage read: $disk_usage%"
    publish_state "Disk usage" "sensor" "disk_usage" "Disk Usage $DISK_PATH" ',"unit_of_measurement":"%","state_class":"measurement","icon":"mdi:harddisk"' "$disk_usage" "Disk usage unavailable"
  fi

}

main "$@"
