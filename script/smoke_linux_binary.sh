#!/bin/sh
# Test a frozen binary in a minimal distribution without installing Python.
set -eu
binary=${1:?Usage: smoke_linux_binary.sh BINARY VERSION}
version=${2:?Expected version is required}
test "$("$binary" version)" = "$version"
"$binary" version --json | grep -F "\"version\": \"$version\""
"$binary" --help >/dev/null
for subcommand in login auth stack notebook note upload download operation index; do
  "$binary" "$subcommand" --help >/dev/null
done
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export XDG_CONFIG_HOME="$test_dir/한글 설정"
mkdir -p "$XDG_CONFIG_HOME/synonote"
chmod 700 "$XDG_CONFIG_HOME/synonote"
printf '%s\n' '{"server":"https://127.0.0.1:1","username":"test"}' > "$XDG_CONFIG_HOME/synonote/profile.json"
printf '%s\n' '{"password":"test-only"}' > "$XDG_CONFIG_HOME/synonote/credentials.json"
chmod 600 "$XDG_CONFIG_HOME/synonote/"*.json
"$binary" logout --json | grep -F 'logged_out'
test ! -e "$XDG_CONFIG_HOME/synonote/credentials.json"
# Exercise packaged SSL/httpx/certificate loading. No real NAS is contacted.
if printf 'test-only\n' | HTTPS_PROXY= HTTP_PROXY= ALL_PROXY= NO_PROXY=127.0.0.1 \
  "$binary" login --server https://127.0.0.1:1 --username test \
  --password-stdin --non-interactive --json > "$test_dir/transport.json"; then
  echo 'Connection to the unused local port unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'TRANSPORT_ERROR' "$test_dir/transport.json"
if grep -F 'test-only' "$test_dir/transport.json"; then exit 1; fi
echo "PASS: $(uname -m), version/help, Unicode state, logout, SSL transport"
