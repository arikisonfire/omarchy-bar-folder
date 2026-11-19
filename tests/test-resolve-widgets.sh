#!/bin/bash
# Tests for resolve-widgets.sh: Bar Folder must load exactly the widgets the
# shell's plugin registry would load, from crafted plugins in a throwaway HOME.
# First-party manifests come from $OMARCHY_PATH (default /usr/share/omarchy).
#
# Usage: tests/test-resolve-widgets.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RESOLVE="$HERE/../resolve-widgets.sh"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
[[ -d $OMARCHY_PATH/shell/plugins ]] || { echo "no first-party plugins in $OMARCHY_PATH" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/bar-folder-resolve.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
P="$HOME/.config/omarchy/plugins"

plugin() {
  mkdir -p "$P/$1"
  printf '%s\n' "$2" >"$P/$1/manifest.json"
  : >"$P/$1/Widget.qml"
}
widget() { printf '{"schemaVersion":1,"id":"%s","name":"N","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"Widget.qml"}%s}' "$1" "${2:-}"; }

plugin good "$(widget test.good ',"barWidget":{"defaultSection":"right"}')"
plugin traysection "$(widget test.traysection ',"barWidget":{"defaultSection":"tray"}')"
plugin badsection "$(widget test.badsection ',"barWidget":{"defaultSection":"middle"}')"
plugin nullsection "$(widget test.nullsection ',"barWidget":{"defaultSection":null}')"
plugin spoof "$(widget omarchy.network)"
plugin reserved "$(widget omarchy.not-a-builtin)"
plugin slash "$(widget test/slash)"
plugin escape '{"schemaVersion":1,"id":"test.escape","name":"N","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"../escape.qml"}}'
plugin encoded '{"schemaVersion":1,"id":"test.encoded","name":"N","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"%2e%2e/escape.qml"}}'
plugin disabled "$(widget test.disabled)"
plugin noschema '{"id":"test.noschema","name":"N","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"Widget.qml"}}'
plugin audioclone "$(widget test.audioclone ',"omarchy":{"clonedFrom":"omarchy.audio"}')"
plugin netclone "$(widget test.netclone ',"omarchy":{"clonedFrom":"omarchy.network"}')"

mkdir -p "$HOME/.config/omarchy"
cat >"$HOME/.config/omarchy/shell.json" <<'EOF'
{"disabledPlugins": ["test.disabled"], "bar": {"layout": {"right": [{"id": "test.netclone"}]}}}
EOF

result=$(bash "$RESOLVE" test.good test.traysection test.badsection test.nullsection omarchy.network \
  omarchy.not-a-builtin test/slash test.escape test.encoded test.disabled test.noschema omarchy.audio)

pass=0
failn=0
expect() {
  local got
  got=$(jq -r --arg id "$1" '.[] | select(.id == $id) | if .url == "" then "refused" else .pluginId end' <<<"$result")
  if [[ $got == "$2" ]]; then echo "ok   $1 -> $2"; pass=$((pass + 1)); else echo "FAIL $1: want $2, got $got"; failn=$((failn + 1)); fi
}

expect test.good test.good
expect test.traysection test.traysection
expect test.badsection refused
expect test.nullsection refused
expect omarchy.not-a-builtin refused
expect test/slash refused
expect test.escape refused
expect test.disabled refused
expect test.noschema refused
# An enabled clone (in the layout) stands in for the built-in; one that is
# not enabled does not, and a third-party plugin never takes a built-in id.
expect omarchy.network test.netclone
expect omarchy.audio omarchy.audio
# The encoded path stays inside the plugin: "%2e%2e" is a folder name there.
encoded=$(jq -r '.[] | select(.id == "test.encoded") | .url' <<<"$result")
if [[ $encoded == *"/encoded/%252e%252e/escape.qml" ]]; then echo "ok   test.encoded stays inside its folder"; pass=$((pass + 1)); else echo "FAIL test.encoded: $encoded"; failn=$((failn + 1)); fi

echo "passed=$pass failed=$failn"
[[ $failn -eq 0 ]]
