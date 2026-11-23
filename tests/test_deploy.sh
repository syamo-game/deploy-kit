#!/usr/bin/env bash
# Tests for the pure helper functions in remote/deploy.sh.
# Run anywhere with bash:  bash tests/test_deploy.sh
# The Docker steps are checked by running the script against a real Docker.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../remote/deploy.sh
source "$here/../remote/deploy.sh"
set +e

fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    printf '       want: %s\n       got:  %s\n' "${want//$'\n'/|}" "${got//$'\n'/|}"
    fails=$((fails + 1))
  fi
}

expect_ok() { "$@" >/dev/null 2>&1; expect_eq "$1 ${2:-} accepts" 0 "$?"; }
expect_ng() { "$@" >/dev/null 2>&1; expect_eq "$1 ${2:-} rejects" 1 "$?"; }

D1="sha256:$(printf 'a%.0s' {1..64})"
D2="sha256:$(printf 'b%.0s' {1..64})"
D3="sha256:$(printf 'c%.0s' {1..64})"
D4="sha256:$(printf 'd%.0s' {1..64})"
R="ghcr.io/example-owner/example-app"

# --- input checks (values reach a remote shell, so they must be strict) ----
expect_ok is_valid_app_name "example-app"
expect_ok is_valid_app_name "web2"
expect_ng is_valid_app_name "Example_App"
expect_ng is_valid_app_name "../etc"
expect_ng is_valid_app_name ""

expect_ok is_valid_image_ref "$R@$D1"
expect_ng is_valid_image_ref "$R:latest"
expect_ng is_valid_image_ref "docker.io/x/y@$D1"
expect_ng is_valid_image_ref "$R@$D1;rm -rf /"
expect_ng is_valid_image_ref "$R@sha256:abc"

expect_eq "image_repo strips the digest" "$R" "$(image_repo "$R@$D1")"

# --- disk space -------------------------------------------------------------
expect_ok has_enough_space 3000 2048
expect_ok has_enough_space 2048 2048
expect_ng has_enough_space 2047 2048

# --- keep only the newest N -------------------------------------------------
got="$(printf '%s\n' new mid old older | items_beyond 2)"
expect_eq "items_beyond 2 lists everything after the newest two" $'old\nolder' "$got"

got="$(printf '%s\n' only | items_beyond 3)"
expect_eq "items_beyond lists nothing when there are fewer items" "" "$got"

# Backup names start with a UTC timestamp, so name order is age order.
touch "$tmp/20261101T010000Z-aaaaaaa.dump" "$tmp/20261103T010000Z-ccccccc.dump" \
  "$tmp/20261102T010000Z-bbbbbbb.dump" "$tmp/20261104T010000Z-ddddddd.dump" \
  "$tmp/notes.txt"
got="$(old_backups "$tmp" 3)"
expect_eq "old_backups keeps the 3 newest dumps and ignores other files" \
  "$tmp/20261101T010000Z-aaaaaaa.dump" "$got"

# --- deploy history ---------------------------------------------------------
hist="$tmp/history"
printf '%s\n' "$R@$D2" "$R@$D1" >"$hist"
update_history "$hist" "$R@$D3" 3
expect_eq "update_history puts the new image first" \
  "$R@$D3"$'\n'"$R@$D2"$'\n'"$R@$D1" "$(cat "$hist")"

update_history "$hist" "$R@$D4" 3
expect_eq "update_history drops the oldest beyond the limit" \
  "$R@$D4"$'\n'"$R@$D3"$'\n'"$R@$D2" "$(cat "$hist")"

update_history "$hist" "$R@$D3" 3
expect_eq "update_history moves a re-deployed image to the top" \
  "$R@$D3"$'\n'"$R@$D4"$'\n'"$R@$D2" "$(cat "$hist")"

got="$(previous_image "$hist")"
expect_eq "previous_image reads the newest entry" "$R@$D3" "$got"

got="$(previous_image "$tmp/missing")"
expect_eq "previous_image is empty on the first deploy" "" "$got"

# --- local images to delete -------------------------------------------------
got="$(printf '%s\n' "$R@$D1" "$R@$D2" "$R@$D3" "$R@$D4" | images_to_remove "$hist")"
expect_eq "images_to_remove lists images that are not in the history" "$R@$D1" "$got"

got="$(printf '%s\n' "$R@<none>" "$R@$D3" | images_to_remove "$hist")"
expect_eq "images_to_remove skips entries without a digest" "" "$got"

echo
if ((fails > 0)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
