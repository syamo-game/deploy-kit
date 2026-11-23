#!/usr/bin/env bash
# Runs on the VPS. Swaps one service to a new image with Docker Compose.
#
#   deploy.sh <app-name> <image-ref> < registry-token
#
#   app-name    lower-case name; the service lives in /opt/<app-name>
#   image-ref   ghcr.io/<owner>/<name>@sha256:<digest>
#   stdin       a short-lived GHCR token (GITHUB_TOKEN of the Actions run)
#
# /opt/<app-name> holds compose.yml (sent by Actions) and .env (server only).
# Order: check disk -> pull -> back up the db -> migrate -> start and wait
# for health -> on failure go back to the previous image -> clean up.
#
# Settings (environment variables):
#   KEEP_IMAGES=3     images kept on the VPS (the running one included)
#   KEEP_BACKUPS=3    database dumps kept in /opt/<app-name>/backups
#   MIN_FREE_MB=2048  stop before anything changes if less disk is free
#   WAIT_SECONDS=180  how long to wait for containers to become healthy
#   APPS_ROOT=/opt

set -euo pipefail

KEEP_IMAGES="${KEEP_IMAGES:-3}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
WAIT_SECONDS="${WAIT_SECONDS:-180}"
APPS_ROOT="${APPS_ROOT:-/opt}"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Pure helpers (covered by tests/test_deploy.sh) -------------------------

is_valid_app_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

is_valid_image_ref() {
  [[ "$1" =~ ^ghcr\.io/[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9._-]*@sha256:[0-9a-f]{64}$ ]]
}

image_repo() { printf '%s\n' "${1%@*}"; }

has_enough_space() { (($1 >= $2)); }

# Read a newest-first list on stdin, print the entries after the first N.
items_beyond() { tail -n +"$(($1 + 1))"; }

# Print the dump files in DIR that are older than the newest N.
old_backups() {
  local dir="$1" keep="$2"
  find "$dir" -maxdepth 1 -type f -name '[0-9]*T[0-9]*Z-*.dump' | sort -r | items_beyond "$keep"
}

# Put IMAGE first in the history file, without duplicates, at most N lines.
update_history() {
  local file="$1" image="$2" keep="$3" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  {
    printf '%s\n' "$image"
    if [[ -f "$file" ]]; then grep -vxF "$image" "$file" || true; fi
  } | head -n "$keep" >"$tmp"
  mv "$tmp" "$file"
}

previous_image() {
  if [[ -f "$1" ]]; then head -n 1 "$1"; fi
}

# Read local image refs (repo@digest) on stdin, print those not in history.
images_to_remove() {
  local history="$1" ref
  while IFS= read -r ref; do
    [[ "$ref" == *@sha256:* ]] || continue
    if ! grep -qxF "$ref" "$history" 2>/dev/null; then printf '%s\n' "$ref"; fi
  done
}

# ---- Steps that touch Docker ------------------------------------------------

compose() { docker compose -p "$APP" -f compose.yml "$@"; }

free_mb() { df -Pm "$1" | awk 'NR == 2 { print $4 }'; }

# "migrate" sits in the "ops" profile so "up" does not start it; list that
# profile too, or Compose hides the service.
has_service() { compose --profile ops config --services | grep -qxF "$1"; }

check_disk() {
  local path mb
  for path in "$APP_DIR" "$(docker info --format '{{.DockerRootDir}}')"; do
    mb="$(free_mb "$path")"
    has_enough_space "$mb" "$MIN_FREE_MB" ||
      die "only ${mb} MB free at $path (need ${MIN_FREE_MB} MB). Nothing was changed. Free space with: docker system df"
  done
}

pull_image() {
  local token
  token="$(cat)"
  [[ -n "$token" ]] || die "no registry token on stdin"
  # A private Docker config keeps the token out of ~/.docker for good.
  DOCKER_CONFIG="$(mktemp -d)"
  export DOCKER_CONFIG
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  printf '%s' "$token" | docker login ghcr.io -u "${GHCR_USER:?GHCR_USER is not set}" --password-stdin >/dev/null
  docker pull --quiet "$IMAGE" >/dev/null
  docker logout ghcr.io >/dev/null
}

# Dump the database only when the compose file has a running "db" service.
backup_db() {
  has_service db || { log "no db service; skipping the backup"; return; }
  [[ -n "$(compose ps -q db)" ]] || { log "db is not running yet; skipping the backup"; return; }

  local name file
  name="$(date -u +%Y%m%dT%H%M%SZ)-${IMAGE##*:}"
  file="backups/${name:0:24}.dump"
  mkdir -p backups
  compose exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"$file" ||
    { rm -f "$file"; die "pg_dump failed. Nothing was changed."; }
  [[ -s "$file" ]] || { rm -f "$file"; die "pg_dump wrote an empty file. Nothing was changed."; }
  log "database saved to $APP_DIR/$file"

  local old
  while IFS= read -r old; do
    rm -f "$old"
    log "removed old backup $old"
  done < <(old_backups backups "$KEEP_BACKUPS")
}

# Called as an "if" condition, where "set -e" does not apply, so every step
# returns on failure by hand.
start_with() {
  export APP_IMAGE="$1"
  if has_service migrate; then
    compose --profile ops run --rm migrate || { log "migration failed"; return 1; }
  fi
  compose up -d --remove-orphans --wait --wait-timeout "$WAIT_SECONDS" ||
    { log "containers did not become healthy within ${WAIT_SECONDS}s"; return 1; }
}

roll_back() {
  local prev="$1"
  if [[ -z "$prev" ]]; then
    die "the new image did not become healthy, and there is no previous image to go back to"
  fi
  log "going back to $prev"
  export APP_IMAGE="$prev"
  compose up -d --remove-orphans --wait --wait-timeout "$WAIT_SECONDS" ||
    die "the previous image did not start either. Check: docker compose -p $APP logs"
  die "the new image did not become healthy; the previous image is running again. Database migrations are not undone; the backup is in $APP_DIR/backups"
}

clean_up() {
  local ref
  while IFS= read -r ref; do
    docker image rm "$ref" >/dev/null && log "removed old image $ref"
  done < <(docker image ls --digests --format '{{.Repository}}@{{.Digest}}' "$(image_repo "$IMAGE")" |
    images_to_remove .deploy/history)
  docker image prune -f >/dev/null
}

main() {
  [[ $# -eq 2 ]] || die "usage: deploy.sh <app-name> <image-ref> < token"
  APP="$1"
  IMAGE="$2"
  is_valid_app_name "$APP" || die "bad app name: $APP"
  is_valid_image_ref "$IMAGE" || die "bad image ref: $IMAGE"

  APP_DIR="$APPS_ROOT/$APP"
  [[ -f "$APP_DIR/compose.yml" ]] || die "$APP_DIR/compose.yml is missing"
  cd "$APP_DIR"
  mkdir -p .deploy

  log "deploying $IMAGE"
  check_disk
  pull_image
  local prev
  prev="$(previous_image .deploy/history)"
  backup_db

  if ! start_with "$IMAGE"; then
    roll_back "$prev"
  fi

  update_history .deploy/history "$IMAGE" "$KEEP_IMAGES"
  clean_up
  log "done: $APP is running $IMAGE"
  compose ps
}

# Run only when executed, not when sourced by the tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
