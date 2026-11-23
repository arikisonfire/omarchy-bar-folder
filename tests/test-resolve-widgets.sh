#!/bin/bash
# Tests for resolve-widgets.sh: Bar Folder must load exactly the widgets the
# shell's plugin registry would load, from crafted plugins in a throwaway HOME,
# and must put nothing from shell.json or about the installed plugins on a
# command line. First-party manifests come from $OMARCHY_PATH (default
# /usr/share/omarchy).
#
# The resolver runs with a PATH that holds only shims for the commands it
# uses (jq, find, sort). Each shim records its arguments, so canaries from
# shell.json, a plugin folder name and a folder id can be checked against
# everything other local accounts could read in /proc/<pid>/cmdline. A command
# without a shim is not found, so none can run unrecorded.
#
# Usage: tests/test-resolve-widgets.sh
set -u
unset BASH_ENV

HERE=$(cd "$(dirname "$0")" && pwd)
RESOLVE="$HERE/../resolve-widgets.sh"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
[[ -d $OMARCHY_PATH/shell/plugins ]] || { echo "no first-party plugins in $OMARCHY_PATH" >&2; exit 2; }
type -P jq >/dev/null || { echo "jq not found" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/bar-folder-resolve.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
P="$HOME/.config/omarchy/plugins"
CFG="$HOME/.config/omarchy/shell.json"
SECRET="CANARY-SECRET-4d1e"

mkdir -p "$T/bin"
for tool in jq find sort; do
  real=$(type -P "$tool") || { echo "$tool not found" >&2; exit 2; }
  cat >"$T/bin/$tool" <<EOF
#!/bin/bash
printf '%s\0' $tool "\$@" >>"$T/argv.log"
exec "$real" "\$@"
EOF
  chmod +x "$T/bin/$tool"
done

# resolve <json array of ids> [args...]: the resolver's output, run the way
# Bar Folder runs it, with the ids in its environment.
resolve() {
  local ids=$1
  shift
  PATH="$T/bin" BAR_FOLDER_WIDGETS="$ids" "$BASH" "$RESOLVE" "$@" 2>>"$T/stderr.log"
}

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
# Names another third-party plugin as its source and is enabled: still no
# takeover of that plugin's tile and settings.
plugin thirdclone "$(widget test.thirdclone ',"omarchy":{"clonedFrom":"test.good"}')"
# Manifests JSON.parse refuses, although jq reads them.
plugin nan "$(widget test.nan ',"x":nan')"
plugin infinity "$(widget test.infinity ',"x":-Infinity')"
plugin leadingzero "$(widget test.leadingzero ',"x":01')"
plugin halfnumber "$(widget test.halfnumber ',"x":.5')"
plugin trailing "$(widget test.trailing) x"
plugin twovalues "$(widget test.twovalues) {}"
# Strings that merely contain such words are fine, and so is a leading byte
# order mark, which the registry trims away.
plugin wordy "$(widget test.wordy ',"description":"NaN, Infinity, 01 and \"nan\" in text","n":-0.5E-3')"
plugin bom $'\xef\xbb\xbf'"$(widget test.bom)"
# Two folders with one id: the registry keeps the later valid manifest.
plugin dup-a "$(widget test.dup)"
plugin dup-b '{"schemaVersion":1,"id":"test.dup","name":"N","version":"1","kinds":["panel"],"entryPoints":{"panel":"Widget.qml"}}'
plugin same-a "$(widget test.same)"
plugin same-b "$(widget test.same)"
plugin canary-folder-4d1e "$(widget test.canary4d1e)"

mkdir -p "$HOME/.config/omarchy"
cat >"$CFG" <<EOF
{"disabledPlugins": ["test.disabled"],
 "bar": {"layout": {"right": [
   {"id": "test.netclone"},
   {"id": "test.thirdclone", "token": "$SECRET"},
   {"id": "io.github.arikisonfire.bar-folder", "widgets": ["test.canary4d1e"],
    "widgetSettings": {"test.canary4d1e": {"password": "$SECRET"}}}]}}}
EOF

result=$(resolve '["test.good","test.traysection","test.badsection","test.nullsection","omarchy.network",
  "omarchy.not-a-builtin","test/slash","test.escape","test.encoded","test.disabled","test.noschema","omarchy.audio",
  "test.nan","test.infinity","test.leadingzero","test.halfnumber","test.trailing","test.twovalues","test.wordy","test.bom",
  "test.dup","test.same","test.canary4d1e",
  "builtin.notifications","io.github.arikisonfire.bar-folder"]')

pass=0
failn=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; failn=$((failn + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1"; echo "       want: $3"; echo "       got:  $2"; fi; }
expect() {
  local got
  got=$(jq -r --arg id "$1" '.[] | select(.id == $id) | if .builtin then "builtin" elif .url == "" then "refused" else .pluginId end' <<<"$result")
  check "$1 -> $2" "$got" "$2"
}

echo "== the registry's rules"
expect test.good test.good
expect test.traysection test.traysection
expect test.badsection refused
expect test.nullsection refused
expect omarchy.not-a-builtin refused
expect test/slash refused
expect test.escape refused
expect test.disabled refused
expect test.noschema refused
expect builtin.notifications builtin
expect io.github.arikisonfire.bar-folder refused
# An enabled clone (in the layout) stands in for the built-in; one that is
# not enabled does not, and a third-party plugin never takes a built-in id.
expect omarchy.network test.netclone
expect omarchy.audio omarchy.audio
# The encoded path stays inside the plugin: "%2e%2e" is a folder name there.
encoded=$(jq -r '.[] | select(.id == "test.encoded") | .url' <<<"$result")
check "test.encoded stays inside its folder" "$([[ $encoded == *"/encoded/%252e%252e/escape.qml" ]] && echo yes || echo "$encoded")" yes

echo "== clones only stand in for built-ins"
expect test.good test.good

echo "== manifests JSON.parse would refuse"
expect test.nan refused
expect test.infinity refused
expect test.leadingzero refused
expect test.halfnumber refused
expect test.trailing refused
expect test.twovalues refused
expect test.wordy test.wordy
expect test.bom test.bom

echo "== one id in two folders: the later valid manifest wins"
expect test.dup refused
same=$(jq -r '.[] | select(.id == "test.same") | .url' <<<"$result")
check "test.same comes from the later folder" "$([[ $same == */same-b/Widget.qml ]] && echo yes || echo "$same")" yes

echo "== the folder's ids come only from the environment"
expect test.canary4d1e test.canary4d1e
check "ids on the command line are ignored" "$(resolve '' test.good | jq -c .)" "[]"
check "a list that is not JSON resolves to nothing" "$(resolve 'test.good' | jq -c .)" "[]"
check "a list that is no array resolves to nothing" "$(resolve '{"a":"test.good"}' | jq -c .)" "[]"

echo "== a broken shell.json is read as empty"
cp "$CFG" "$T/shell.json.saved"
printf '{"disabledPlugins": ["test.good"]} {}\n' >"$CFG"
check "two JSON values: no plugin counts as disabled" "$(resolve '["test.good"]' | jq -r '.[0].pluginId')" test.good
printf '{"disabledPlugins": ["test.good"]\n' >"$CFG"
check "cut-off JSON: no plugin counts as disabled" "$(resolve '["test.good"]' | jq -r '.[0].pluginId')" test.good
cp "$T/shell.json.saved" "$CFG"

echo "== nothing private on a command line"
commands=$(tr '\0' '\n' <"$T/argv.log" | grep -cx jq || true)
check "the shims recorded the resolver's jq runs" "$([[ $commands -gt 0 ]] && echo yes || echo no)" yes
leaks=$(tr '\0' '\n' <"$T/argv.log" | grep -c -e "$SECRET" -e "canary-folder-4d1e" -e "test.canary4d1e" -e "$P" || true)
check "no setting, plugin folder or folder id in any argument" "$leaks" 0
check "no command missing from the shims" "$(grep -c "command not found" "$T/stderr.log" 2>/dev/null || true)" 0

echo "passed=$pass failed=$failn"
[[ $failn -eq 0 ]]
