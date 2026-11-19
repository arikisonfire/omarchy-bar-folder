#!/bin/bash
# Moves widgets between the bar layout and Bar Folder, atomically.
#
#   layout.sh setup   <id>...                                  first run: move these widgets into the folder
#   layout.sh absorb  <id> [index] [--entry-env]               bar -> folder (index -1 = end)
#   layout.sh release <id> [anchor-id] [before|after] [nth] [--from <i>]
#                                                              folder -> bar, next to anchor
#                                                              (default: just before the folder icon)
#   layout.sh reorder <id> <index> [--from <i>]                move a tile inside the folder
#   layout.sh release-all                                      put every widget back on the bar (before uninstalling)
#
# The folder entry lists its tiles in `widgets`. A plain id is a widget whose
# inline bar settings live in widgetSettings[id], as in earlier versions. A
# widget that is already in the folder can come in again (one tray widget per
# tray app, say); every further instance is an object like a bar entry,
# {"id": ..., <its settings>}. So there is at most one plain id per widget and
# widgetSettings stays unambiguous.
#
#   - `absorb --entry-env` moves the dragged bar entry, read from
#     $BAR_FOLDER_ENTRY. It is never taken from the command line, which other
#     local accounts can read in /proc. Without the flag the first entry with
#     the id moves.
#   - `--from <i>` names the tile by its position in `widgets`, so the right
#     one of several instances moves; without it the first tile with the id.
#   - `release ... <nth>` lands next to the nth bar entry (from 0, in bar order)
#     with the anchor id.
#
# Inline bar settings travel along both ways. Built-in tiles (builtin.*) have
# no bar widget, so releasing one just removes it. Nothing here runs unless
# the user drags something or confirms first-run setup. A failed command
# leaves shell.json as it was, logs why to the user journal
# (journalctl --user -t bar-folder) and shows a notification.

set -euo pipefail

FOLDER_ID="io.github.arikisonfire.bar-folder"

valid_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* && $1 != "$FOLDER_ID" ]]
}

valid_anchor() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $1 != *..* ]]
}

HELPERS='
  def entry_id: if type == "object" then (.id // "" | tostring) else tostring end;
  def as_object: if type == "object" then . else {id: tostring} end;
  # Every section that holds widgets, in bar order (Omarchy 4.5), then any
  # section this script does not know yet.
  def sections:
    ["left", "centerBegin", "center", "centerEnd", "right", "tray"] as $known
    | ((.bar.layout // {}) | to_entries | map(select(.value | type == "array") | .key)) as $have
    | ($known | map(. as $s | select($have | index($s) != null))) + ($have - $known);
  def bar_entries:
    sections[] as $s | .bar.layout[$s] | to_entries[] | {section: $s, index: .key, entry: .value};
  def each_section(f):
    .bar.layout |= with_entries(.value |= (if type == "array" then f else . end));
  def insert_at($item; $index):
    if $index < 0 or $index > length then . + [$item] else .[:$index] + [$item] + .[$index:] end;
  def folder_location: first(bar_entries | select(.entry | entry_id == $folder) | [.section, .index]) // null;
  def folder_entry: first(bar_entries | select(.entry | entry_id == $folder) | .entry) // null;
  def folder_update(f): each_section(map(if entry_id == $folder then f else . end));
  def require_folder: if folder_location == null then error("Bar Folder is not on the bar") else . end;
  def folder_widgets: (folder_entry // {}) | .widgets | if type == "array" then . else [] end;
  def has_plain($id): folder_widgets | any(.[]; type == "string" and . == $id);
  def first_location($id): first(bar_entries | select(.entry | entry_id == $id) | [.section, .index]) // null;
  def entry_location($id; $entry):
    first(bar_entries | select((.entry | entry_id == $id) and ((.entry | as_object) == $entry)) | [.section, .index]) // null;
  def settings_at($p): .bar.layout[$p[0]][$p[1]] | if type == "object" then del(.id) else {} end;
  def drop_at($p): .bar.layout[$p[0]] |= del(.[$p[1]]);
  # widgetSettings[$id] belongs to the plain id; nothing stale may outlive it.
  def set_settings($id; $inline):
    if ($inline | length) > 0 then .widgetSettings = ((.widgetSettings // {}) + {($id): $inline})
    elif .widgetSettings then .widgetSettings |= del(.[$id])
    else . end;
  # The tile to move: position $from when it holds $id, else the first $id.
  def tile_index($id; $from):
    folder_widgets as $w
    | if $from == null then (first($w | to_entries[] | select(.value | entry_id == $id) | .key) // null)
      elif $from < ($w | length) and ($w[$from] | entry_id) == $id then $from
      else null end;
  # The bar entry a tile stands for, with its settings.
  def tile_entry($host; $tile):
    if ($tile | type) == "object" then {id: ($tile | entry_id)} + ($tile | del(.id))
    else
      ((($host.widgetSettings // {})[$tile | entry_id] // {}) | if type == "object" then del(.id) else {} end) as $saved
      | {id: ($tile | entry_id)} + $saved
    end;
  # Putting a widget back never wipes other instances of the same widget:
  # only an exact duplicate of the entry goes first.
  def without_equal_entry($entry): each_section(map(select(as_object != $entry)));
'

# Runs in a subshell, so the helper's own EXIT trap (it removes its temp file)
# fires there and a failure here can still be reported below.
main() {
  local positional=() from=null from_env=false
  while (($#)); do
    case $1 in
      --entry-env) from_env=true ;;
      --from)
        shift
        [[ ${1:-} =~ ^[0-9]+$ ]] || fail "invalid tile position: ${1:-}"
        from=$1
        ;;
      --*) fail "unknown option: $1" ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  set -- ${positional[@]+"${positional[@]}"}

  source omarchy-shell-config

  # The helper writes a temp file and moves it over shell.json. From /tmp that
  # move is a copy to another file system; next to shell.json it is a rename.
  config_dir=$(dirname -- "$CONFIG_FILE")
  mkdir -p -- "$config_dir"
  export TMPDIR=$config_dir

  # Serialize edits: every command reads shell.json, changes it and writes it
  # back, and two quick drags would otherwise overwrite each other. The lock is
  # taken on the config directory itself, so no lock file is created.
  exec {lock_fd}<"$config_dir"
  flock -w 10 "$lock_fd" || fail "timed out waiting for another layout change"

  case $command in
    setup)
      for id in "$@"; do valid_id "$id" || fail "invalid id: $id"; done
      ids=$(if (($#)); then printf '%s\n' "$@"; fi | jq -R . | jq -s -c 'map(select(. != ""))')
      commit "$NORMALIZE | $HELPERS
        require_folder
        | folder_update(.widgets = (.widgets // []))
        | reduce \$ids[] as \$id (.;
            if (folder_widgets | any(.[]; entry_id == \$id)) then . else
              first_location(\$id) as \$p
              | (if \$p == null then {} else settings_at(\$p) end) as \$inline
              | (if \$p == null then . else drop_at(\$p) end)
              | folder_update(.widgets = ((.widgets // []) + [\$id]) | set_settings(\$id; \$inline))
            end)
      " --arg folder "$FOLDER_ID" --argjson ids "$ids"
      ;;

    absorb)
      (($# >= 1 && $# <= 2)) || fail "usage: absorb <id> [index] [--entry-env]"
      id=$1
      index=${2:--1}
      valid_id "$id" || fail "invalid id: $id"
      [[ $index =~ ^-?[0-9]+$ ]] || fail "invalid index: $index"
      if [[ $from_env == true ]]; then
        [[ -n ${BAR_FOLDER_ENTRY:-} ]] || fail "no dragged entry in BAR_FOLDER_ENTRY"
        jq -e --arg id "$id" 'type == "object" and (.id | type == "string") and .id == $id' \
          <<<"$BAR_FOLDER_ENTRY" >/dev/null 2>&1 || fail "the dragged entry is not a $id entry"
      fi
      commit "$NORMALIZE | $HELPERS
        require_folder
        | (if \$from_env then (\$ENV.BAR_FOLDER_ENTRY | fromjson) else null end) as \$entry
        | (if \$entry == null then first_location(\$id) else entry_location(\$id; \$entry) end) as \$p
        | if \$p == null then error(\"\(\$id) is no longer on the bar\") else . end
        | settings_at(\$p) as \$inline
        | has_plain(\$id) as \$again
        | drop_at(\$p)
        | folder_update(
            if \$again then .widgets = ((.widgets // []) | insert_at({id: \$id} + \$inline; \$index))
            else .widgets = ((.widgets // []) | insert_at(\$id; \$index)) | set_settings(\$id; \$inline) end)
      " --arg folder "$FOLDER_ID" --arg id "$id" --argjson index "$index" --argjson from_env "$from_env"
      ;;

    release)
      (($# >= 1 && $# <= 4)) || fail "usage: release <id> [anchor] [before|after] [nth] [--from <i>]"
      id=$1
      anchor=${2:-$FOLDER_ID}
      side=${3:-before}
      nth=${4:-0}
      valid_id "$id" || fail "invalid id: $id"
      valid_anchor "$anchor" || fail "invalid anchor: $anchor"
      [[ $side == before || $side == after ]] || fail "invalid side: $side"
      [[ $nth =~ ^[0-9]+$ ]] || fail "invalid anchor position: $nth"
      commit "$NORMALIZE | $HELPERS
        (folder_entry // {}) as \$host
        | tile_index(\$id; \$from) as \$i
        | if \$i == null then error(\"\(\$id) is not in the folder there\") else . end
        | (folder_widgets[\$i]) as \$tile
        | tile_entry(\$host; \$tile) as \$entry
        | folder_update(
            .widgets = ((.widgets // []) | del(.[\$i]))
            | if (\$tile | type) != \"object\" and .widgetSettings then .widgetSettings |= del(.[\$id]) else . end)
        | if (\$id | startswith(\"builtin.\")) then . else
            without_equal_entry(\$entry)
            | ([bar_entries | select(.entry | entry_id == \$anchor) | [.section, .index]]) as \$anchors
            | (\$anchors[\$nth] // \$anchors[0] // null) as \$a
            | if \$a != null then
                .bar.layout[\$a[0]] |= insert_at(\$entry; (if \$after then \$a[1] + 1 else \$a[1] end))
              else
                folder_location as \$f
                | if \$f == null then .bar.layout.right = ((.bar.layout.right // []) + [\$entry])
                  else .bar.layout[\$f[0]] |= insert_at(\$entry; \$f[1]) end
              end
          end
      " --arg folder "$FOLDER_ID" --arg id "$id" --arg anchor "$anchor" --argjson nth "$nth" \
        --argjson from "$from" --argjson after "$([[ $side == after ]] && echo true || echo false)"
      ;;

    release-all)
      # Before uninstalling: every widget goes back to the bar, just before the folder.
      commit "$NORMALIZE | $HELPERS
        folder_entry as \$host
        | if \$host == null then . else
            (folder_widgets
              | map(select(type == \"string\" or (type == \"object\" and (.id | type) == \"string\")))
              | map(select(entry_id | startswith(\"builtin.\") | not))) as \$tiles
            | reduce \$tiles[] as \$tile (.;
                tile_entry(\$host; \$tile) as \$entry
                | without_equal_entry(\$entry)
                | folder_location as \$f
                | .bar.layout[\$f[0]] |= insert_at(\$entry; \$f[1]))
            | folder_update(.widgets = [] | del(.widgetSettings))
          end
      " --arg folder "$FOLDER_ID"
      ;;

    reorder)
      (($# == 2)) || fail "usage: reorder <id> <index> [--from <i>]"
      id=$1
      index=$2
      valid_id "$id" || fail "invalid id: $id"
      [[ $index =~ ^[0-9]+$ ]] || fail "invalid index: $index"
      commit "$NORMALIZE | $HELPERS
        tile_index(\$id; \$from) as \$i
        | if \$i == null then error(\"\(\$id) is not in the folder there\") else . end
        | folder_update(
            (.widgets // []) as \$w
            | .widgets = ((\$w | del(.[\$i])) | insert_at(\$w[\$i]; \$index)))
      " --arg folder "$FOLDER_ID" --arg id "$id" --argjson index "$index" --argjson from "$from"
      ;;

    *)
      fail "unknown command: $command"
      ;;
  esac
}

describe() {
  local id=${1:-}
  valid_anchor "$id" || id="a widget"
  case $command in
    setup) echo "move the default icons into the folder" ;;
    absorb) echo "move $id into the folder" ;;
    release) echo "put $id back on the bar" ;;
    release-all) echo "put the icons back on the bar" ;;
    reorder) echo "move $id inside the folder" ;;
    *) echo "change the bar layout" ;;
  esac
}

log_errors() {
  if command -v logger >/dev/null 2>&1; then logger -t bar-folder; else cat >/dev/null; fi
}

command=${1:-}
shift || true

status=0
(main "$@") 2> >(log_errors) || status=$?

if ((status != 0)) && command -v notify-send >/dev/null 2>&1; then
  notify-send -a "Bar Folder" "Bar Folder" \
    "Could not $(describe "${1:-}"). Nothing was changed. Details: journalctl --user -t bar-folder" \
    >/dev/null 2>&1 || true
fi
exit "$status"
