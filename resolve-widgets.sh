#!/bin/bash
# Resolves the widgets in the folder to their QML entry points.
#
#   BAR_FOLDER_WIDGETS='["omarchy.audio", ...]' resolve-widgets.sh
#   ->  JSON array of {id, pluginId, url, name, builtin, serviceUrl, manifest}
#
# Ids starting with `builtin.` are tiles Bar Folder draws itself.
#
# Nothing from shell.json and nothing about the installed plugins goes on a
# command line, which other local accounts can read in /proc: the folder's ids
# arrive in the environment, shell.json and every manifest reach jq on stdin,
# and a manifest's directory reaches jq in its environment. Every jq command
# line holds a fixed program only.
#
# Resolution follows the shell's plugin registry, so hosting a widget in the
# folder never loads code the shell itself would refuse to load:
#   - manifests are validated the same way (exactly one JSON object, which
#     JSON.parse would accept; schemaVersion 1; id, name, version, kinds and
#     entryPoints; entry points relative and without `..`; a valid
#     `barWidget.defaultSection`), and the last valid manifest under an id
#     wins, as in the registry;
#   - plugins listed in `disabledPlugins` are not loaded;
#   - first-party plugins win; third-party plugins cannot claim an
#     `omarchy.*` id or the id of a first-party plugin;
#   - a clone (omarchy.clonedFrom, as `omarchy plugin clone` makes it) stands
#     in only for a built-in, and only while that clone is enabled in
#     shell.json or sits in the folder itself. A plugin that names any other
#     plugin as its source never takes over that plugin's tile or settings.
#
# `serviceUrl` is set for third-party plugins that also declare a service,
# but only while the shell does not run that service itself (the plugin is
# neither in the bar layout nor in `plugins`). Bar Folder then runs it, so
# there is always exactly one instance. Services the shell treats specially
# are never hosted: `keepLoaded` ones and clones of first-party plugins with
# the `authentication` capability (lock, polkit), which the shell keeps
# isolated from every plugin.

set -euo pipefail

user_dir="$HOME/.config/omarchy/plugins"
system_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins"
config_file="$HOME/.config/omarchy/shell.json"
folder_id="io.github.arikisonfire.bar-folder"

# One manifest file on stdin -> one record, or nothing when the file is not
# exactly one JSON object with a string id.
MANIFEST='
  def safe_entry: type == "string" and length > 0
    and (startswith("/") | not) and (contains("..") | not);
  # Omarchy 4.5 rejects the whole manifest when barWidget.defaultSection is
  # set to anything but a bar section.
  def valid_default_section:
    (.barWidget | if type == "object" and has("defaultSection")
      then (.defaultSection | tostring | IN("left", "centerBegin", "center", "centerEnd", "right", "tray"))
      else true end);
  # The registry trims the text and parses it with JSON.parse. Outside
  # strings jq also reads what JSON.parse refuses: NaN, Infinity and numbers
  # such as 01, 1., .5 or +1. So outside strings only punctuation, JSON
  # whitespace, true, false, null and JSON numbers may appear.
  def json_parse_accepts:
    gsub("\"([^\"\\\\]|\\\\.)*\""; " ") | gsub("true|false|null"; " ")
    | test("^[ \\t\\n\\r{}\\[\\],:]*(-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][-+]?[0-9]+)?(?=[ \\t\\n\\r{}\\[\\],:]|$)[ \\t\\n\\r{}\\[\\],:]*)*$");
  ltrimstr("﻿")
  | select(json_parse_accepts)
  | fromjson
  | select(type == "object" and (.id | type == "string"))
  | (.schemaVersion == 1
      and has("name") and has("version") and has("kinds") and has("entryPoints")
      and (.id | length > 0 and (contains("/") | not) and (contains("..") | not))
      and (.kinds | type == "array" and length > 0)
      and (.entryPoints | type == "object" and ([.[] | safe_entry] | all))
      and valid_default_section) as $valid
  | {
      id,
      firstParty: ($ENV.BAR_FOLDER_KIND == "firstparty"),
      valid: $valid,
      authentication: ((.omarchy | objects | .capabilities | arrays) // [] | index("authentication") != null),
      clonedFrom: ((.omarchy | objects | .clonedFrom | strings) // ""),
      keepLoaded: (.keepLoaded == true),
      widget: (if $valid and (.kinds | index("bar-widget") != null) and (.entryPoints.barWidget | type == "string")
        then {
          name: ((.barWidget | objects | .displayName | strings) // (.name | tostring)),
          path: ($ENV.BAR_FOLDER_DIR + "/" + .entryPoints.barWidget),
          servicePath: (if (.kinds | index("service") != null) and (.entryPoints.service | type == "string")
            then $ENV.BAR_FOLDER_DIR + "/" + .entryPoints.service else "" end),
          manifest: (if (.kinds | index("service") != null) then . else null end)
        }
        else null end)
    }'

# The manifest's path stays off jq's command line: the file is its stdin, its
# directory and kind are in its environment.
emit() {
  BAR_FOLDER_KIND=$1 BAR_FOLDER_DIR=${2%/*} jq -c -R -s "$MANIFEST" 2>/dev/null <"$2" || true
}

# Every manifest the registry scans, in its order: first-party ones (also
# sibling *.manifest.json files one level deeper), then the user's plugins.
scan_manifests() {
  local file
  if [[ -d $system_dir ]]; then
    while IFS= read -r -d '' file; do emit firstparty "$file"; done \
      < <(find "$system_dir" -mindepth 2 -maxdepth 3 -type f \( -name manifest.json -o -name '*.manifest.json' \) -print0 2>/dev/null | sort -z)
  fi
  for file in "$user_dir"/*/manifest.json; do
    if [[ -f $file ]]; then emit thirdparty "$file"; fi
  done
}

records=$(scan_manifests | jq -s -c '.')

config='{}'
if [[ -s $config_file ]]; then
  config=$(jq -c -s 'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' 2>/dev/null <"$config_file" || echo '{}')
fi

# printf is a shell builtin: the manifests and shell.json reach jq through the
# pipe without a command line of their own.
printf '%s\n%s\n' "$records" "$config" | jq -n --arg folder "$folder_id" '
  def entry_id: if type == "object" then (.id // "" | tostring) else tostring end;
  def valid_id: test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not);
  def file_url: "file://" + (split("/") | map(@uri) | join("/"));
  [inputs] as [$records, $config]
  | (($ENV.BAR_FOLDER_WIDGETS // "[]") | try fromjson catch []
     | if type == "array" then map(select(type == "string" and . != "")) else [] end) as $ids
  | {"builtin.notifications": "Notifications"} as $builtins
  | ($records | map(select(.firstParty and .authentication) | .id) | unique) as $authentication
  | ($records | map(select(.valid))) as $valid
  | ($valid | map(select(.firstParty) | .id) | unique) as $first
  # As in the registry: the last valid manifest under an id wins, first-party
  # plugins first; a third-party plugin never takes a first-party or
  # omarchy.* id.
  | (reduce ($valid[] | select(.firstParty)) as $r ({}; .[$r.id] = $r)) as $firstparty
  | (reduce ($valid[] | select((.firstParty | not) and (.id | startswith("omarchy.") | not)
                               and (.id | IN($first[]) | not))) as $r ({}; .[$r.id] = $r)) as $thirdparty
  | ([($config.bar | objects | .layout | objects | .[] | arrays | .[] | entry_id),
      ($config.plugins | arrays | .[] | entry_id),
      ($config.bar | objects | .id | strings)] | map(select(. != ""))) as $referenced
  | (($config.disabledPlugins | arrays) // []) as $disabled
  | ($referenced + $ids) as $active
  | [$ids[] as $id
     | if $builtins[$id] then {id: $id, pluginId: $id, url: "", name: $builtins[$id], builtin: true, serviceUrl: ""}
       elif ($id | valid_id | not) or $id == $folder
       then {id: $id, pluginId: $id, url: "", name: $id, builtin: false, serviceUrl: ""}
       else
         # A built-in is replaced by its enabled clone, as the registry routes
         # calls to it; anything else is the plugin registered under its id.
         ((if $firstparty[$id] then
             [$thirdparty[] | select(.clonedFrom == $id and .widget != null
                                     and (.id | IN($active[])) and (.id | IN($disabled[]) | not))][0]
           else null end)
          // (if $id | IN($disabled[]) then null
              else (($firstparty[$id] // $thirdparty[$id]) as $r
                    | if $r != null and $r.widget != null then $r else null end)
              end)) as $hit
         | if $hit
           then ((($hit.firstParty | not) and $hit.widget.servicePath != ""
                  and ($hit.keepLoaded | not)
                  and ($hit.clonedFrom | IN($authentication[]) | not)
                  and ($hit.id | IN($referenced[]) | not)) as $hosted
                 | {id: $id, pluginId: $hit.id, url: ($hit.widget.path | file_url), name: $hit.widget.name, builtin: false,
                    serviceUrl: (if $hosted then ($hit.widget.servicePath | file_url) else "" end),
                    manifest: (if $hosted then $hit.widget.manifest else null end)})
           else {id: $id, pluginId: $id, url: "", name: $id, builtin: false, serviceUrl: ""}
           end
       end]
'
