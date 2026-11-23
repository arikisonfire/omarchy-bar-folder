# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**. If that button is missing, open an issue that only says you found a security problem, without details, and you will get a way to send them privately.

## What Bar Folder does

- It runs inside the Omarchy shell with your user's rights. It needs no sudo, makes no network connections and starts no processes of its own, apart from its helper scripts and the services of plugins you put into the folder.
- It reads plugin manifests from `~/.config/omarchy/plugins` and from the Omarchy installation, and loads only widgets the shell itself would load (see "How it works" in the README).
- It writes only `~/.config/omarchy/shell.json`, through Omarchy's `omarchy-shell-config` helper, and only after you drag something or confirm the first-run prompt. Each change goes to a temporary file next to `shell.json` that is then renamed over it.
- Nothing from your configuration goes on a command line, which other local accounts could read in the process list:
  - the settings of a widget you drag into the folder reach `layout.sh` in an environment variable;
  - the folder's widget list reaches `resolve-widgets.sh` in its environment, and `shell.json` and the plugin manifests reach `jq` on its standard input;
  - when a widget in the folder opens another plugin's panel, such as the network widget opening the Wi-Fi share card with the network's name, the call goes to the shell's IPC inside the shell, the way `omarchy-shell` delivers it. No process is started for it. On Omarchy versions before 4.5, which lack that path, the call goes through `omarchy-shell` without those details.
- A plugin that names another plugin as its source (`omarchy.clonedFrom`) only stands in for a built-in Omarchy widget, as `omarchy plugin clone` makes it, and only while it is enabled. It never takes over the tile of another plugin, or the settings that come with it.
- When a layout change fails, nothing is written. Bar Folder shows a notification and logs the reason to your user journal (`journalctl --user -t bar-folder`). The log names widget ids, not their settings.

## Trust

Widgets inside the folder run with the same rights as on the bar, and Omarchy plugins are not sandboxed. Only put plugins into the folder that you would also trust on your bar.
