#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${HOME}/.medialibrarian"
SETTINGS_FILE="${CONFIG_DIR}/settings.yml"
API_FILE="${CONFIG_DIR}/api.yml"

log() {
  printf '\n%s\n' "$1"
}

run_as_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_package_manager() {
  local managers=(pacman apt-get apt dnf yum zypper apk)
  for candidate in "${managers[@]}"; do
    if command -v "$candidate" &>/dev/null; then
      case "$candidate" in
        apt-get|apt)
          echo "apt"
          return
          ;;
        *)
          echo "$candidate"
          return
          ;;
      esac
    fi
  done
  return 1
}

install_system_dependencies() {
  local manager
  if manager=$(detect_package_manager); then
    :
  else
    manager=""
  fi

  case "$manager" in
    pacman)
      log "==> Installing system packages with pacman"
      run_as_root pacman -Sy --needed --noconfirm flac lame mediainfo mkvtoolnix-cli
      if ! command -v ffmpeg &>/dev/null; then
        echo "→ Installing ffmpeg-full from AUR (requires trizen or yay)"
        if command -v trizen &>/dev/null; then
          if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            echo "⚠️  Run this script as a regular user to let trizen install ffmpeg-full automatically." >&2
          else
            trizen -S --noconfirm ffmpeg-full
          fi
        elif command -v yay &>/dev/null; then
          if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            echo "⚠️  Run this script as a regular user to let yay install ffmpeg-full automatically." >&2
          else
            yay -S --noconfirm ffmpeg-full
          fi
        else
          printf '%s\n' "⚠️  No AUR helper (trizen, yay, …) detected. Install ffmpeg-full manually or rerun after installing one." >&2
        fi
      fi
      ;;
    apt)
      log "==> Installing system packages with apt"
      run_as_root apt-get update
      run_as_root apt-get install -y flac lame mediainfo ffmpeg mkvtoolnix
      ;;
    dnf)
      log "==> Installing system packages with dnf"
      run_as_root dnf install -y flac lame-tools mediainfo ffmpeg mkvtoolnix
      ;;
    yum)
      log "==> Installing system packages with yum"
      run_as_root yum install -y flac lame mediainfo ffmpeg mkvtoolnix
      ;;
    zypper)
      log "==> Installing system packages with zypper"
      run_as_root zypper --non-interactive install flac lame mediainfo ffmpeg mkvtoolnix
      ;;
    apk)
      log "==> Installing system packages with apk"
      run_as_root apk add --no-cache flac lame mediainfo ffmpeg mkvtoolnix make
      ;;
    *)
      printf '%s\n' "⚠️  Supported package manager not detected. Install the following manually: flac, lame, mediainfo, ffmpeg (or ffmpeg-full), mkvtoolnix, MakeMKV." >&2
      ;;
  esac

  if ! command -v makemkvcon &>/dev/null; then
    printf '%s\n' "⚠️  MakeMKV was not found on this system. Install makemkv-bin manually from your distribution or from https://www.makemkv.com/download/." >&2
  fi
}

install_ruby_dependencies() {
  log "==> Installing Ruby dependencies"
  if ! gem list bundler -i --version ">= 2.3.22" &>/dev/null; then
    echo "→ Installing Bundler 2.3.22"
    gem install bundler:2.3.22
  fi
  bundle config set deployment 'true'
  bundle install --jobs 4 --retry 3
}

yaml_escape() {
  local value="$1" dq='"' escaped_dq='\"' backslash='\' escaped_backslash='\\'
  value=${value//${backslash}/${escaped_backslash}}
  value=${value//${dq}/${escaped_dq}}
  printf '"%s"' "$value"
}

yaml_line() {
  local key="$1" value="$2"
  if [[ -z "$value" ]]; then
    printf '%s:%s\n' "$key" ""
  else
    printf '%s: %s\n' "$key" "$(yaml_escape "$value")"
  fi
}

prompt_with_default() {
  local prompt="$1" default="$2" response
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " response || true
  else
    read -r -p "$prompt: " response || true
  fi
  if [[ -z "$response" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$response"
  fi
}

prompt_yes_no() {
  local prompt="$1" default="$2" response
  local hint="y/N"
  if [[ "$default" == "y" || "$default" == "Y" ]]; then
    hint="Y/n"
  fi
  read -r -p "$prompt [$hint]: " response || true
  response=${response:-$default}
  [[ "$response" =~ ^[Yy]$ ]]
}

prompt_secret() {
  local prompt="$1" value
  read -r -s -p "$prompt: " value || true
  echo
  printf '%s' "$value"
}

generate_bcrypt_hash() {
  local plain confirm password_hash
  plain=$(prompt_secret "Enter password")
  confirm=$(prompt_secret "Confirm password")
  if [[ "$plain" != "$confirm" ]]; then
    echo "Passwords do not match. Please try again." >&2
    generate_bcrypt_hash
    return
  fi
  if [[ -z "$plain" ]]; then
    echo "Password cannot be empty." >&2
    generate_bcrypt_hash
    return
  fi
  password_hash=$(PASSWORD="$plain" bundle exec ruby -rbcrypt -e 'require "bcrypt"; print BCrypt::Password.create(ENV.fetch("PASSWORD"))')
  printf '%s' "$password_hash"
}

configure_web_interface() {
  log "==> Configuring web interface"
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    cp "$REPO_ROOT/config/conf.yml.example" "$SETTINGS_FILE"
    echo "→ Created $SETTINGS_FILE from template"
  fi

  local bind_address listen_port username password_hash ssl_enabled cert_path key_path ca_path verify_mode client_verify_mode api_token control_token

  bind_address=$(prompt_with_default "Bind address" "127.0.0.1")
  listen_port=$(prompt_with_default "HTTP port" "8888")
  username=$(prompt_with_default "Admin username" "admin")

  if prompt_yes_no "Do you already have a BCrypt password hash to reuse?" "n"; then
    password_hash=$(prompt_with_default "Enter existing password hash" "")
  else
    password_hash=$(generate_bcrypt_hash)
  fi

  if prompt_yes_no "Enable HTTPS" "n"; then
    ssl_enabled="true"
    cert_path=$(prompt_with_default "Path to SSL certificate" "")
    key_path=$(prompt_with_default "Path to SSL private key" "")
    ca_path=$(prompt_with_default "Path to CA bundle (optional)" "")
    verify_mode=$(prompt_with_default "SSL verify mode (none/peer/force_peer/etc.)" "peer")
    client_verify_mode=$(prompt_with_default "Client certificate verification mode" "none")
  else
    ssl_enabled="false"
    cert_path=""
    key_path=""
    ca_path=""
    verify_mode="none"
    client_verify_mode="none"
  fi

  api_token=$(prompt_with_default "API token (leave blank to disable)" "")
  control_token=$(prompt_with_default "Control token (leave blank to disable)" "")

  printf '---\n' >"$API_FILE"
  yaml_line bind_address "$bind_address" >>"$API_FILE"
  echo "listen_port: ${listen_port:-8888}" >>"$API_FILE"
  {
    echo "auth:" >>"$API_FILE"
    yaml_line "  username" "$username" >>"$API_FILE"
    yaml_line "  password_hash" "$password_hash" >>"$API_FILE"
  }
  echo "ssl_enabled: $ssl_enabled" >>"$API_FILE"
  yaml_line ssl_certificate_path "$cert_path" >>"$API_FILE"
  yaml_line ssl_private_key_path "$key_path" >>"$API_FILE"
  yaml_line ssl_ca_path "$ca_path" >>"$API_FILE"
  yaml_line ssl_verify_mode "$verify_mode" >>"$API_FILE"
  yaml_line ssl_client_verify_mode "$client_verify_mode" >>"$API_FILE"
  yaml_line api_token "$api_token" >>"$API_FILE"
  yaml_line control_token "$control_token" >>"$API_FILE"
  echo "→ Saved web configuration to $API_FILE"
}

main() {
  log "==> Installing system dependencies"
  install_system_dependencies
  install_ruby_dependencies
  configure_web_interface
  log "✅  Installation complete"
  echo "You can start the daemon with:"
  echo "  bundle exec ruby librarian.rb daemon start --config $SETTINGS_FILE"
}

main "$@"
