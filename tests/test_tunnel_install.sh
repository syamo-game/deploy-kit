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

is_masked_paste "cloudflared.exe service install eyJhIjoi********************bSJ9"
expect_eq "is_masked_paste spots the dashboard's masked display" 0 "$?"

is_masked_paste "$TOKEN"
expect_eq "is_masked_paste accepts a real token" 1 "$?"

# describe_input explains a failed paste without showing the input itself.
got="$(describe_input "")"
expect_eq "describe_input reports an empty paste" "received 0 characters in 0 words; no word starts with eyJ" "$got"

got="$(describe_input $'\x16')"
expect_eq "describe_input counts a lone control character" "received 1 characters in 1 words; no word starts with eyJ" "$got"

got="$(describe_input "eyJabc def")"
expect_eq "describe_input notices a token-like word" "received 10 characters in 2 words; a word starts with eyJ" "$got"

got="$(describe_input "$TOKEN")"
[[ "$got" != *"$TOKEN"* && "$got" != *eyJh* ]]
expect_eq "describe_input never prints the input" 0 "$?"

echo
if ((fails > 0)); then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
