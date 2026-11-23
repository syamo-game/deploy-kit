#!/usr/bin/env bash
# Installs the Cloudflare Tunnel connector on the VPS. Safe to run again.
#
#   bash install.sh
#
# Run it as a user that can use Docker, next to compose.yml.
# It asks for the tunnel token once (input is hidden) and keeps it in
# /opt/tunnel/.env, readable only by its owner. Nothing else changes:
# Caddy, the open ports and the DNS records stay as they are.

set -euo pipefail

TUNNEL_DIR="${TUNNEL_DIR:-/opt/tunnel}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---- Pure helper (covered by tests/test_tunnel_install.sh) ------------------

# Print the tunnel token found in the input. The input may be the bare token
# or the whole command the dashboard shows ("... --token <token>").
# A token is base64 of a JSON object, so it starts with "eyJ".
extract_token() {
  local word found="" words=()
  # Split on spaces without expanding "*" into file names.
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    if [[ "$word" == eyJ* ]]; then found="$word"; fi
  done
  [[ -n "$found" ]] || return 1
  [[ "$found" =~ ^[A-Za-z0-9+/=_-]{80,}$ ]] || return 1
  printf '%s\n' "$found"
}

# The dashboard shows the token with "*" in place of most characters.
# Selecting that text copies the stars, not the token.
is_masked_paste() { [[ "$1" == *eyJ*'***'* ]]; }

# Say what arrived, without printing it, so a failed paste can be diagnosed.
describe_input() {
  local words=() word starts="no word starts with eyJ"
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    if [[ "$word" == eyJ* ]]; then starts="a word starts with eyJ"; fi
  done
  printf 'received %d characters in %d words; %s\n' "${#1}" "${#words[@]}" "$starts"
}

# ---- Steps ------------------------------------------------------------------

main() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$here/compose.yml" ]] || die "compose.yml must be next to install.sh ($here)"
  docker compose version >/dev/null || die "docker compose is not available for this user"
  docker network inspect proxy >/dev/null 2>&1 ||
    die "the shared Docker network 'proxy' does not exist. The services expect it; check with: docker network ls"

  log "Preparing $TUNNEL_DIR"
  if [[ ! -d "$TUNNEL_DIR" ]]; then
    if [[ -w "$(dirname "$TUNNEL_DIR")" ]]; then
      install -d -m 750 "$TUNNEL_DIR"
    else
      sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 750 "$TUNNEL_DIR"
    fi
  fi
  install -m 644 "$here/compose.yml" "$TUNNEL_DIR/compose.yml"

  if [[ -f "$TUNNEL_DIR/.env" ]]; then
    log "Keeping the token already in $TUNNEL_DIR/.env"
  else
    local input token
    printf '\nPaste the tunnel token (or the whole command from the dashboard), then press Enter.\n'
    printf 'The input is hidden.\n> '
    read -rs input
    printf '\n(%s)\n' "$(describe_input "$input")"
    if is_masked_paste "$input"; then
      die "this is the masked text shown on the page (it contains ***). Use the copy icon at the right end of the command box instead of selecting the text."
    fi
    token="$(extract_token "$input")" ||
      die "no tunnel token found in the input. Copy it again from Cloudflare: Networking > Tunnels > your tunnel. If 0 characters arrived, the paste did not reach this window: try right-click or Shift+Insert to paste."
    (umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" >"$TUNNEL_DIR/.env")
    log "Saved the token to $TUNNEL_DIR/.env (mode 600)"
  fi

  log "Starting the connector"
  cd "$TUNNEL_DIR"
  docker compose -p tunnel up -d

  log "Waiting for the connection to Cloudflare (up to 60 seconds)"
  local i
  for i in $(seq 1 30); do
    if docker compose -p tunnel logs cloudflared 2>&1 | grep -q 'Registered tunnel connection'; then
      log "Connected. The dashboard should now show the tunnel as HEALTHY."
      docker compose -p tunnel ps
      return 0
    fi
    sleep 2
  done
  docker compose -p tunnel logs --tail 40 cloudflared
  die "the connector did not report a connection. The last log lines are above."
}

# Run only when executed, not when sourced by the tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
