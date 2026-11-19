# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**. If that button is missing, open an issue that only says you found a security problem, without details, and you will get a way to send them privately.

## What Bar Folder does

- It runs inside the Omarchy shell with your user's rights. It needs no sudo, makes no network connections and starts no processes of its own, apart from its helper scripts and the services of plugins you put into the folder.
- It reads plugin manifests from `~/.config/omarchy/plugins` and from the Omarchy installation, and loads only widgets the shell itself would load (see "How it works" in the README).
- It writes only `~/.config/omarchy/shell.json`, through Omarchy's `omarchy-shell-config` helper, and only after you drag something or confirm the first-run prompt. Each change goes to a temporary file next to `shell.json` that is then renamed over it.
- The settings of a widget you drag into the folder reach the helper script in an environment variable, never on its command line, which other local accounts could read in the process list.
- When a layout change fails, nothing is written. Bar Folder shows a notification and logs the reason to your user journal (`journalctl --user -t bar-folder`). The log names widget ids, not their settings.

## Trust

Widgets inside the folder run with the same rights as on the bar, and Omarchy plugins are not sandboxed. Only put plugins into the folder that you would also trust on your bar.
