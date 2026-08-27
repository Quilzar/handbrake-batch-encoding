#!/bin/bash

# Enable strict execution, exit immediately on error or unset variables
set -euo pipefail

# Check required environment variables exist
readonly required_env_vars=(
  "HANDBRAKE_APP_DIR"
  "HANDBRAKE_INPUT_DIR"
  "HANDBRAKE_OUTPUT_DIR"
  "PUSHOVER_TOKEN"
  "PUSHOVER_USER_KEY"
)

for var in "${required_env_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    printf "<3>'${var}' environment variable is not set or is empty." >&2
    exit 1
  fi
done

# Define initial variables
readonly app_dir="${HANDBRAKE_APP_DIR}"
readonly base_input_dir="${HANDBRAKE_INPUT_DIR}"
readonly base_output_dir="${HANDBRAKE_OUTPUT_DIR}"
readonly log_dir="${app_dir}/logs"
readonly hostname=$(hostname)
readonly stop_file="${app_dir}/handbrake-batch-encoding.stop"
readonly lock_file="${app_dir}/handbrake-batch-encoding.lock"

# Define profiles
readonly profile_dir="${app_dir}/profiles"
readonly profile="plex-1080p"
#readonly profile="plex-1080p-light-denoise"
readonly preset_file="${profile_dir}/${profile}.json"

# Define functions
send_pushover_message () {
  local -r message="$1"
  local -r level="${2:-normal}"

  local priority=0
  case "${level}" in
    low)       priority=-1 ;;
    normal)    priority=0  ;;
    high)      priority=1  ;;
    emergency) priority=2  ;;
  esac

  local -r token="${PUSHOVER_TOKEN}"
  local -r user_key="${PUSHOVER_USER_KEY}"
  local -r title="Handbrake Batch Encoding"
  local -r url="https://api.pushover.net/1/messages.json"

  curl -s \
    --data-urlencode "token=${token}" \
    --data-urlencode "user=${user_key}" \
    --data-urlencode "title=${title}" \
    --data-urlencode "message=${message}" \
    --data-urlencode "priority=${priority}" \
    "${url}" > /dev/null
}

log_info () {
  printf '<6>%s\n' "$*"
  send_pushover_message "$*"
}

log_error () {
  printf '<3>%s\n' "$*" >&2
  send_pushover_message "$*" "high"
}

acquire_lock () {
  exec 200>"${lock_file}"
  if ! flock -n 200; then
    log_info "Another encoding job is currently running. Exiting."
    exit 0
  fi
}

get_duration () {
  local -r start_time="${1:?[ERROR] start_time argument required but not passed}"
  local -r elapsed_time=$(($(date +%s) - start_time))
  local -r hours=$(( elapsed_time / 3600 ))
  local -r minutes=$(( ( elapsed_time % 3600 ) / 60 ))
  local -r seconds=$(( elapsed_time % 60 ))

  printf "%02dh %02dm %02ds" "$hours" "$minutes" "$seconds"
}

validate_environment () {
  if [[ ! -f "${preset_file}" ]]; then
    log_error "Can't find Handbrake preset file '${preset_file}'."
    exit 1
  fi

  mkdir -p "${log_dir}" "${base_output_dir}"

  # notify systemd we are good to go!
  if [[ -n "${NOTIFY_SOCKET:-}" ]]; then
    systemd-notify --ready --status="Starting batch encoding..."
  fi
}

cleanup () {
  log_info "Termination signal received. Killing child processes."

  # Unbind signal handlers to prevent infinite trap loops
  trap - SIGTERM SIGINT

  # Kill all child processes (Flatpak / HandBrake / tee) under this PID
  pkill -P $$ || true
  exit 143
}

throttle_progress () {
  python3 -c '
import sys
import re

c, buf = 0, ""
timestamp_pattern = re.compile(r"^\[\d{2}:\d{2}:\d{2}\] ?")

for ch in iter(lambda: sys.stdin.read(1), ""):
  if ch in "\r\n":
    line = buf.rstrip("\r\n")
    cleaned = timestamp_pattern.sub("", line)
    stripped = cleaned.strip()
    if stripped.startswith("Encoding:"):
      c += 1
      if c % 300 == 0:
        print(cleaned, flush=True)
    elif stripped:
      print(cleaned, flush=True)
    buf = ""
  else:
    buf += ch
'
}

encode_movie () {
  local -r movie="$1"
  local -r output_dir="${base_output_dir}/${movie}"
  local -r input_file="${base_input_dir}/${movie}/movie.mkv"
  local -r output_file="${base_output_dir}/${movie}/movie.mkv.partial"
  local -r final_file="${base_output_dir}/${movie}/movie.mkv"
  local -r log_file="${log_dir}/${movie}.log"
  local -r start_time=$(date +%s)

  # check files and folders exist
  if [[ -f "${final_file}" ]]; then
    log_info "Skipping '${movie}' final file already exists."
    return 0
  fi

  if [[ ! -f "${input_file}" ]]; then
    log_error "Input file missing '${input_file}'"
    return 1
  fi

  mkdir -p "${output_dir}"

  # notify systemd what movie we are processing
  if [[ -n "${NOTIFY_SOCKET:-}" ]]; then
      systemd-notify --status="Processing ${movie}."
  fi

  # encode movie
  HandBrakeCLI \
    --preset-import-file "${preset_file}" \
    -Z "${profile}" \
    -i "${input_file}" \
    -o "${output_file}" 2>&1 \
    | throttle_progress \
    | tee "${log_file}"

  local -r exit_code="${PIPESTATUS[0]}"

  local -r duration=$(get_duration "${start_time}")

  if [[ ${exit_code} -ne 0 ]]; then
    log_error "Failed encoding '${movie}' after ${duration}. See log '${log_file}'"
    return 1
  fi

  local -r file_size=$(du -h "${output_file}" | awk '{print $1}')

  mv -f "${output_file}" "${final_file}" || {
    log_error "Failed to move '${output_file}' to '${final_file}'."
    return 1
  }

  log_info "Finished encoding '${movie}' in ${duration}. The encoded file was ${file_size}."
}

main () {
  # enviroment tests and setup
  acquire_lock
  trap cleanup SIGTERM SIGINT
  validate_environment

  # Create movie array from subdirectories in base_input_dir
  local movies
  mapfile -t movies < <(find "${base_input_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

  # Process all movies
  local movie

  for movie in "${movies[@]}"; do
    # Check for stop flag file
    if [[ -f "${stop_file}" ]]; then
      log_info "Stop file detected. Halting batch processing."
      rm -f "${stop_file}"
      return 0
    fi

    encode_movie "${movie}" || true
  done

  sleep 3
  log_info "Finished batch encoding."
}

main "$@"
