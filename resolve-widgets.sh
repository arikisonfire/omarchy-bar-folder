#!/bin/bash
# Resolves bar-widget ids to their QML entry points.
# Usage: resolve-widgets.sh <id>...
#   ->  JSON array of {id, pluginId, url, name, builtin, serviceUrl, manifest}
# Ids starting with `builtin.` are tiles Bar Folder draws itself.
#
# Resolution follows the shell's plugin registry, so hosting a widget in the
# folder never loads code the shell itself would refuse to load:
#   - manifests are validated the same way (schemaVersion, id, kind
#     `bar-widget`, relative entry points without `..`);
#   - plugins listed in `disabledPlugins` are not loaded;
#   - first-party plugins win; third-party plugins cannot claim an
#     `omarchy.*` id or the id of a first-party plugin;
#   - a local clone (omarchy.clonedFrom) only replaces the built-in when that
#     clone is enabled in shell.json or sits in the folder itself.
#
# `serviceUrl` is set for third-party plugins that also declare a service,
# but only while the shell does not run that service itself (the plugin is
# neither in the bar layout nor in `plugins`). Bar Folder then runs it, so
# there is always exactly one instance. Bar Folder itself is `keepLoaded`, so
# hosted services with the same flag retain their promised hot-reload lifetime.
# Clones of first-party plugins with the `authentication` capability (lock,
# polkit) are never hosted; the shell keeps them isolated from every plugin.

set -euo pipefail

user_dir="$HOME/.config/omarchy/plugins"
system_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins"
config_file="$HOME/.config/omarchy/shell.json"
folder_id="io.github.arikisonfire.bar-folder"

emit() {
  local kind=$1 file=$2
  jq -c --arg dir "$(dirname -- "$file")" --arg kind "$kind" '
    def safe_entry: type == "string" and length > 0
      and (startswith("/") | not) and (contains("..") | not);
    select(type == "object"
      and .schemaVersion == 1
      and (.id | type == "string" and length > 0 and (contains("/") | not) and (contains("..") | not))
      and .name != null and .version != null
      and (.kinds | type == "array" and index("bar-widget") != null)
      and (.entryPoints | type == "object" and ([.[] | safe_entry] | all))
      and (.entryPoints.barWidget | type == "string"))
    | {
        id,
        firstParty: ($kind == "firstparty"),
        clonedFrom: ((.omarchy | objects | .clonedFrom | strings) // ""),
        name: ((.barWidget | objects | .displayName | strings) // (.name | tostring)),
        path: ($dir + "/" + .entryPoints.barWidget),
        servicePath: (if (.kinds | index("service") != null) and (.entryPoints.service | type == "string")
          then $dir + "/" + .entryPoints.service else "" end),
        manifest: (if (.kinds | index("service") != null) then . else null end)
      }' "$file" 2>/dev/null || true
}

catalog=$(
  {
    if [[ -d $system_dir ]]; then
      find "$system_dir" -mindepth 2 -maxdepth 3 -type f \( -name manifest.json -o -name '*.manifest.json' \) -print0 2>/dev/null \
        | sort -z | while IFS= read -r -d '' file; do emit firstparty "$file"; done
    fi
    for file in "$user_dir"/*/manifest.json; do
      if [[ -f $file ]]; then emit thirdparty "$file"; fi
    done
  } | jq -s '
    (map(select(.firstParty) | .id) | unique) as $first
    | map(select(.firstParty or ((.id | startswith("omarchy.") | not) and (.id | IN($first[]) | not))))'
)

# First-party plugins with the `authentication` capability (lock, polkit).
# They are services only, so they are not in the widget catalog above.
authentication='[]'
if [[ -d $system_dir ]]; then
  authentication=$(
    find "$system_dir" -mindepth 2 -maxdepth 3 -type f \( -name manifest.json -o -name '*.manifest.json' \) -print0 2>/dev/null \
      | xargs -0 -r jq -c 'select(type == "object" and (.id | type == "string")
          and ((.omarchy | objects | .capabilities | arrays) // [] | index("authentication") != null)) | .id' 2>/dev/null \
      | jq -s -c 'unique' || echo '[]'
  )
fi

config='{}'
if [[ -s $config_file ]]; then
  config=$(jq -c 'if type == "object" then . else {} end' "$config_file" 2>/dev/null || echo '{}')
fi

# Ids travel as one JSON value, never as jq command-line arguments.
ids=$(if (($#)); then printf '%s\n' "$@"; fi | jq -R . | jq -s -c 'map(select(. != ""))')

jq -n --argjson catalog "$catalog" --argjson authentication "${authentication:-[]}" --argjson config "$config" --argjson ids "$ids" --arg folder "$folder_id" '
  def entry_id: if type == "object" then (.id // "" | tostring) else tostring end;
  def valid_id: test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not);
  def file_url: "file://" + (split("/") | map(@uri) | join("/"));
  {"builtin.notifications": "Notifications"} as $builtins
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
         # Same precedence as the registry: an enabled clone first, then the
         # last manifest registered under that id (first-party before third-party).
         ([$catalog[] | select((.firstParty | not) and .clonedFrom == $id
                               and (.id | IN($active[])) and (.id | IN($disabled[]) | not))][0]
          // (if $id | IN($disabled[]) then null
              else ([$catalog[] | select(.id == $id and .firstParty)] | last)
                // ([$catalog[] | select(.id == $id and (.firstParty | not))] | last)
              end)) as $hit
         | if $hit
           then ((($hit.firstParty | not) and $hit.servicePath != ""
                  and ($hit.clonedFrom | IN($authentication[]) | not)
                  and ($hit.id | IN($referenced[]) | not)) as $hosted
                 | {id: $id, pluginId: $hit.id, url: ($hit.path | file_url), name: $hit.name, builtin: false,
                    serviceUrl: (if $hosted then ($hit.servicePath | file_url) else "" end),
                    manifest: (if $hosted then $hit.manifest else null end)})
           else {id: $id, pluginId: $id, url: "", name: $id, builtin: false, serviceUrl: ""}
           end
       end]
'
