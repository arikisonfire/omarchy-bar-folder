#!/bin/bash
# Tests for layout.sh against throwaway copies of shell.json, using Omarchy's
# own omarchy-shell-config helper. Nothing outside a temporary directory is
# touched, and the running shell is never asked to reload.
#
# Usage: tests/test-layout.sh [path/to/omarchy-shell-config]
#
# jq, notify-send, logger and omarchy-shell are replaced by shims that record
# their arguments (logger also its input), so a canary in a dragged entry can
# be checked against everything other local accounts could read in
# /proc/<pid>/cmdline.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LAYOUT="$HERE/../layout.sh"
HELPER=${1:-$(command -v omarchy-shell-config || true)}
REAL_JQ=$(command -v jq || true)
[[ -n $HELPER && -f $HELPER ]] || { echo "omarchy-shell-config not found; pass its path" >&2; exit 2; }
[[ -n $REAL_JQ ]] || { echo "jq not found" >&2; exit 2; }
CANARY="CANARY-7f3a9c"

T=$(mktemp -d "${TMPDIR:-/tmp}/bar-folder-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cp "$HELPER" "$T/bin/omarchy-shell-config"

cat >"$T/bin/jq" <<EOF
#!/bin/bash
printf '%s\0' jq "\$@" >>"$T/argv.log"
exec "$REAL_JQ" "\$@"
EOF
for tool in notify-send omarchy-shell; do
  cat >"$T/bin/$tool" <<EOF
#!/bin/bash
printf '%s\0' $tool "\$@" >>"$T/argv.log"
printf '%s\0' $tool "\$@" >>"$T/$tool.log"
exit 0
EOF
done
cat >"$T/bin/logger" <<EOF
#!/bin/bash
printf '%s\0' logger "\$@" >>"$T/argv.log"
cat >>"$T/logger.log"
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH" HOME="$T/home"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
CFG="$HOME/.config/omarchy/shell.json"
FOLDER='io.github.arikisonfire.bar-folder'

pass=0
failn=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; failn=$((failn + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1"; echo "       want: $3"; echo "       got:  $2"; fi; }
refused() { if [[ $1 -ne 0 ]]; then echo yes; else echo no; fi; }
q() { "$REAL_JQ" -c "$1" "$CFG"; }
hash_cfg() { sha256sum <"$CFG"; }
run() { "$LAYOUT" "$@" >/dev/null 2>&1; local rc=$?; sleep 0.2; return $rc; }
reset_logs() { rm -f "$T/argv.log" "$T/notify-send.log" "$T/logger.log" "$T/omarchy-shell.log"; }
leaked() { cat "$T/argv.log" "$T/logger.log" 2>/dev/null | tr '\0' '\n' | grep -c -- "$CANARY"; }
notified() { if [[ -s $T/notify-send.log ]]; then echo yes; else echo no; fi; }
stray_tmp() { find "$HOME/.config/omarchy" -maxdepth 1 -name 'tmp.*' | wc -l; }
in_folder() { echo ".bar.layout.$1[] | select(.id == \"$FOLDER\")"; }
TRAY='[.bar.layout.right[] | select(.id == "example.tray") | (.items // ["*"])[0]]'
DRAGGED='{"id":"example.tray","items":["dictation"],"note":"'"$CANARY"'"}'

write_config() { mkdir -p "$(dirname "$CFG")"; cat >"$CFG"; reset_logs; }

# One tray widget per icon, the folder in the right section.
fixture_a() {
  write_config <<EOF
{
  "bar": {
    "layout": {
      "left": [{"id": "omarchy.menu"}],
      "centerBegin": [{"id": "example.countdown"}],
      "center": [{"id": "example.indicators", "alwaysShow": false}],
      "centerEnd": [],
      "right": [
        {"id": "omarchy.system-update"},
        {"id": "example.tray", "items": ["vpn"]},
        {"id": "example.tray", "items": ["cloud"]},
        {"id": "example.tray", "items": ["vault"]},
        $DRAGGED,
        {"id": "example.tray"},
        {"id": "example.sandbox", "protected": "work"},
        {"id": "$FOLDER", "widgets": ["example.plugins", "example.stopwatch"],
         "widgetSettings": {"example.stopwatch": {"minutes": 1}}},
        {"id": "omarchy.audio"},
        {"id": "omarchy.clock", "format": "HH:mm"}
      ],
      "tray": [{"id": "example.panel"}]
    }
  },
  "plugins": []
}
EOF
}

# The folder in centerEnd, other widgets in centerBegin (Omarchy 4.5 sections).
fixture_b() {
  write_config <<EOF
{
  "bar": {
    "layout": {
      "left": [],
      "centerBegin": [{"id": "example.countdown"}, {"id": "omarchy.weather"}],
      "center": [{"id": "omarchy.clock"}],
      "centerEnd": [{"id": "$FOLDER", "widgets": ["omarchy.network"],
                     "widgetSettings": {"omarchy.network": {"showName": true}}}],
      "right": [{"id": "omarchy.audio", "showPercent": true}, {"id": "omarchy.power", "showPercentage": true}]
    }
  }
}
EOF
}

# First run: a default widget with inline settings sits in centerBegin.
fixture_c() {
  write_config <<EOF
{
  "bar": {
    "layout": {
      "centerBegin": [{"id": "omarchy.audio", "showPercent": true}],
      "right": [{"id": "omarchy.bluetooth"}, {"id": "$FOLDER"}]
    }
  }
}
EOF
}

echo "== absorb the dragged instance (entry in the environment)"
fixture_a
BAR_FOLDER_ENTRY=$DRAGGED run absorb example.tray -1 --entry-env
check "exit 0" "$?" 0
check "the other instances stay on the bar" "$(q "$TRAY")" '["vpn","cloud","vault","*"]'
check "the widget is last in the folder" "$(q "$(in_folder right) | .widgets")" '["example.plugins","example.stopwatch","example.tray"]'
check "its settings travel along" "$(q "$(in_folder right) | .widgetSettings[\"example.tray\"].items")" '["dictation"]'
check "other widgetSettings untouched" "$(q "$(in_folder right) | .widgetSettings[\"example.stopwatch\"]")" '{"minutes":1}'
check "canary in no argv and no log" "$(leaked)" 0
check "no failure notice on success" "$(notified)" no
check "no temp files left next to shell.json" "$(stray_tmp)" 0

echo "== a second instance of the same widget comes in as its own entry"
reset_logs
BAR_FOLDER_ENTRY='{"id":"example.tray","items":["cloud"]}' run absorb example.tray -1 --entry-env
check "exit 0" "$?" 0
check "it is a tile of its own" "$(q "$(in_folder right) | .widgets")" '["example.plugins","example.stopwatch","example.tray",{"id":"example.tray","items":["cloud"]}]'
check "the first instance keeps its settings" "$(q "$(in_folder right) | .widgetSettings[\"example.tray\"].items")" '["dictation"]'
check "the rest stay on the bar" "$(q "$TRAY")" '["vpn","vault","*"]'
check "canary in no argv" "$(leaked)" 0

echo "== tiles move by position, so the right instance moves"
reset_logs
run reorder example.tray 0 --from 3
check "exit 0" "$?" 0
check "the second instance is first" "$(q "$(in_folder right) | .widgets")" '[{"id":"example.tray","items":["cloud"]},"example.plugins","example.stopwatch","example.tray"]'
before=$(hash_cfg)
run reorder example.tray 0 --from 1
check "a position that holds another widget is refused" "$(refused $?)" yes
check "shell.json unchanged" "$(hash_cfg)" "$before"
check "failure notice shown" "$(notified)" yes
check "notice without entry content" "$(tr '\0' '\n' <"$T/notify-send.log" | grep -c -- "$CANARY")" 0

echo "== each instance goes back where it is dropped (nth, --from)"
reset_logs
run release example.tray example.tray after 1 --from 0
check "exit 0" "$?" 0
check "after the second tray icon on the bar" "$(q "$TRAY")" '["vpn","vault","cloud","*"]'
check "the first instance stays in the folder" "$(q "$(in_folder right) | .widgets")" '["example.plugins","example.stopwatch","example.tray"]'
check "with its settings" "$(q "$(in_folder right) | .widgetSettings[\"example.tray\"].items")" '["dictation"]'
run release example.tray example.tray after 2 --from 2
check "exit 0" "$?" 0
check "after the third tray icon on the bar" "$(q "$TRAY")" '["vpn","vault","cloud","dictation","*"]'
check "settings come back" "$(q '.bar.layout.right[] | select(.id == "example.tray" and .items == ["dictation"]) | .note')" "\"$CANARY\""
check "the folder no longer holds it" "$(q "$(in_folder right) | (.widgets | index(\"example.tray\")) == null and (.widgetSettings | has(\"example.tray\") | not)")" true
check "canary in no argv" "$(leaked)" 0
before=$(hash_cfg)
run release omarchy.clock
check "a widget that is not in the folder is refused" "$(refused $?)" yes
check "shell.json unchanged" "$(hash_cfg)" "$before"

echo "== bad dragged entries change nothing"
fixture_a
before=$(hash_cfg)
BAR_FOLDER_ENTRY='not json' run absorb example.tray -1 --entry-env
check "invalid JSON refused" "$(refused $?)" yes
BAR_FOLDER_ENTRY='{"id":"omarchy.clock"}' run absorb example.tray -1 --entry-env
check "entry of another widget refused" "$(refused $?)" yes
BAR_FOLDER_ENTRY='{"id":"example.tray","items":["nope"]}' run absorb example.tray -1 --entry-env
check "entry no longer on the bar refused" "$(refused $?)" yes
env -u BAR_FOLDER_ENTRY "$LAYOUT" absorb example.tray -1 --entry-env >/dev/null 2>&1
check "flag without entry refused, no fallback" "$(refused $?)" yes
run absorb example.tray -1 "$DRAGGED"
check "entry on the command line refused" "$(refused $?)" yes
check "shell.json unchanged" "$(hash_cfg)" "$before"
check "canary never logged" "$(grep -c -- "$CANARY" "$T/logger.log" 2>/dev/null || true)" 0
check "no temp files left" "$(stray_tmp)" 0

echo "== absorb without an entry moves only the first instance"
fixture_a
run absorb example.tray
check "exit 0" "$?" 0
check "the other four stay" "$(q "$TRAY")" '["cloud","vault","dictation","*"]'
check "settings of the first instance kept" "$(q "$(in_folder right) | .widgetSettings[\"example.tray\"].items")" '["vpn"]'

echo "== reorder never adds a widget"
fixture_a
before=$(q "$(in_folder right) | .widgets")
run reorder omarchy.clock 0
check "widgets unchanged" "$(q "$(in_folder right) | .widgets")" "$before"
run reorder example.stopwatch 0
check "a real reorder works" "$(q "$(in_folder right) | .widgets")" '["example.stopwatch","example.plugins"]'

echo "== folder in centerEnd: absorb"
fixture_b
run absorb omarchy.audio
check "exit 0" "$?" 0
check "in the folder" "$(q "$(in_folder centerEnd) | .widgets")" '["omarchy.network","omarchy.audio"]'
check "settings kept" "$(q "$(in_folder centerEnd) | .widgetSettings[\"omarchy.audio\"]")" '{"showPercent":true}'
check "off the bar" "$(q '[.bar.layout.right[] | .id]')" '["omarchy.power"]'

echo "== release next to an anchor in centerBegin"
fixture_b
run release omarchy.network omarchy.weather before
check "exit 0" "$?" 0
check "lands before Weather" "$(q '[.bar.layout.centerBegin[] | .id]')" '["example.countdown","omarchy.network","omarchy.weather"]'
check "settings restored" "$(q '.bar.layout.centerBegin[] | select(.id == "omarchy.network") | .showName')" true

echo "== release-all with the folder in centerEnd"
fixture_b
run release-all
check "exit 0" "$?" 0
check "widget back before the folder" "$(q '[.bar.layout.centerEnd[] | .id]')" "[\"omarchy.network\",\"$FOLDER\"]"
check "folder emptied" "$(q "$(in_folder centerEnd) | .widgets")" '[]'

echo "== release without a usable anchor goes just before the folder"
fixture_b
run release omarchy.network does.not.exist after
check "exit 0" "$?" 0
check "before the folder" "$(q '[.bar.layout.centerEnd[] | .id]')" "[\"omarchy.network\",\"$FOLDER\"]"

echo "== first-run setup keeps settings of a widget in centerBegin"
fixture_c
run setup omarchy.audio omarchy.bluetooth builtin.notifications
check "exit 0" "$?" 0
check "widgets" "$(q "$(in_folder right) | .widgets")" '["omarchy.audio","omarchy.bluetooth","builtin.notifications"]'
check "settings kept" "$(q "$(in_folder right) | .widgetSettings[\"omarchy.audio\"]")" '{"showPercent":true}'
check "bar emptied" "$(q '[.bar.layout.centerBegin[], .bar.layout.right[] | .id]')" "[\"$FOLDER\"]"

echo "== release-all brings every instance back with its own settings"
write_config <<EOF
{"bar": {"layout": {"right": [{"id": "omarchy.audio"},
  {"id": "$FOLDER", "widgets": ["example.tray", {"id": "example.tray", "items": ["cloud"]}, "builtin.notifications"],
   "widgetSettings": {"example.tray": {"items": ["dictation"]}}}]}}}
EOF
run release-all
check "exit 0" "$?" 0
check "both instances back, in order, before the folder" "$(q '[.bar.layout.right[] | [.id, (.items // [])[0]]]')" "[[\"omarchy.audio\",null],[\"example.tray\",\"dictation\"],[\"example.tray\",\"cloud\"],[\"$FOLDER\",null]]"
check "folder emptied" "$(q "$(in_folder right) | [.widgets, has(\"widgetSettings\")]")" '[[],false]'

echo "== hand-edited oddities do not break release-all"
write_config <<EOF
{"bar": {"layout": {"right": [{"id": "omarchy.audio"},
  {"id": "$FOLDER", "widgets": ["omarchy.network", 42, null, "builtin.notifications"],
   "widgetSettings": {"omarchy.network": {"x": 1}}}], "tray": "not a list"}}}
EOF
run release-all
check "exit 0" "$?" 0
check "only the real widget comes back" "$(q '[.bar.layout.right[] | .id]')" "[\"omarchy.audio\",\"omarchy.network\",\"$FOLDER\"]"
check "a broken section stays as it was" "$(q '.bar.layout.tray')" '"not a list"'

echo "== concurrent drags do not overwrite each other"
write_config <<EOF
{"bar": {"layout": {"right": [{"id": "example.one"}, {"id": "example.two"}, {"id": "example.three"},
  {"id": "$FOLDER", "widgets": []}]}}}
EOF
("$LAYOUT" absorb example.one >/dev/null 2>&1 &
 "$LAYOUT" absorb example.two >/dev/null 2>&1 &
 "$LAYOUT" absorb example.three >/dev/null 2>&1 &
 wait)
check "all three in the folder" "$(q "$(in_folder right) | .widgets | sort")" '["example.one","example.three","example.two"]'
check "none left on the bar" "$(q '[.bar.layout.right[] | .id]')" "[\"$FOLDER\"]"

echo "passed=$pass failed=$failn"
[[ $failn -eq 0 ]]
