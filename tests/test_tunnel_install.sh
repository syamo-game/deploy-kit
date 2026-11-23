#!/usr/bin/env bash
# Tests for the pure helpers in infra/tunnel/install.sh.
# Run anywhere with bash:  bash tests/test_tunnel_install.sh

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/tunnel/install.sh
source "$here/../infra/tunnel/install.sh"
set +e

fails=0
expect_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "ok   - $name"
  else
    printf 'FAIL - %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
    fails=$((fails + 1))
  fi
}

# A made-up token in the same shape as a real one (base64 of JSON).
TOKEN="eyJhIjoiMDEyMzQ1Njc4OWFiY2RlZiIsInQiOiJhYmNkZWYwMS0yMzQ1LTY3ODkiLCJzIjoiWm1GclpTMXpaV055WlhRPSJ9"

got="$(extract_token "$TOKEN")"
expect_eq "extract_token keeps a bare token" "$TOKEN" "$got"

got="$(extract_token "  $TOKEN  ")"
expect_eq "extract_token trims spaces around the token" "$TOKEN" "$got"

got="$(extract_token "docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token $TOKEN")"
expect_eq "extract_token finds the token in a pasted docker command" "$TOKEN" "$got"

got="$(extract_token "sudo cloudflared service install $TOKEN")"
expect_eq "extract_token finds the token in a pasted service command" "$TOKEN" "$got"

extract_token "" >/dev/null 2>&1
expect_eq "extract_token fails on empty input" 1 "$?"

extract_token "hello world" >/dev/null 2>&1
expect_eq "extract_token fails when there is no token" 1 "$?"

extract_token "eyJabc" >/dev/null 2>&1
expect_eq "extract_token fails on a token that is too short" 1 "$?"

extract_token "${TOKEN}\$(reboot)" >/dev/null 2>&1
expect_eq "extract_token fails on characters a token never has" 1 "$?"

echo
if ((fails > 0)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
