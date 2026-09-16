# Omarchy command toggle

A bar widget for the [Omarchy](https://omarchy.org) shell that starts and
stops long-running commands from the bar. Think `kubectl port-forward`,
`ssh -N -L`, a dev server, `tail -f`: anything that blocks until it finishes
or you kill it.

Every command runs as a transient systemd user unit, so it:

- survives shell restarts,
- has its own journal (`journalctl --user -u <unit>`),
- can restart itself when it dies (a port-forward losing its pod, say).

## Install

```bash
omarchy plugin add https://github.com/nachtwerk/omarchy-command-toggle.git --enable
```

Then click the console icon in the bar.

## Remove

```bash
omarchy plugin remove command-toggle
```

Anything still running keeps running until you stop it:

```bash
systemctl --user stop 'omarchy-toggle-*' 'omarchy-once-*'
```

The plugin only ever writes its own entry in `~/.config/omarchy/shell.json`,
which `omarchy plugin remove` takes out again.

## Use

The popup has two sections.

**Saved.** One row per command with a toggle switch. Left click flips it,
right click tails its log in a floating terminal, the trash button removes it.
Saved commands restart on failure.

**Run once.** Type a command and press Enter. It starts immediately and gets a
row with save-to-list, log, and stop buttons. A one-shot that exits 0 shows as
finished; one that exits non-zero shows as failed.

Keyboard: `j`/`k` move, `Enter` toggles, `x` removes or stops, `o` opens the
log, `/` focuses the field, `Esc` leaves it.

The bar icon shows how many commands are running.

## Configuration

Saved commands live on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "command-toggle",
  "commands": [
    { "name": "mysql-proxy", "command": "kubectl port-forward -n prod deploy/mysql-proxy 3308:3306", "restart": true }
  ]
}
```

| Key | Default | Meaning |
|---|---|---|
| `commands` | `[]` | List of `{ name, command, restart }`. `name` becomes the unit name `omarchy-toggle-<name>`. |
| `icon` | `󰆍` | Bar glyph (Nerd Font). |
| `interval` | `3` | Status poll interval in seconds while the popup is closed. |

## Scripting

The widget exposes an IPC target, handy for keybindings:

```bash
omarchy-shell command-toggle state            # JSON of everything
omarchy-shell command-toggle start <name>
omarchy-shell command-toggle stop <name>
omarchy-shell command-toggle flip <name>
omarchy-shell command-toggle run "<command>"  # one-shot
omarchy-shell command-toggle save <name> "<command>"
omarchy-shell command-toggle remove <name>
omarchy-shell command-toggle toggle           # open/close the popup
```

Units can also be driven with plain systemd:

```bash
systemctl --user status omarchy-toggle-mysql-proxy
systemctl --user stop omarchy-toggle-mysql-proxy
```

## How it works

- `Panel.qml` is the bar widget and popup. It polls
  `systemctl --user list-units 'omarchy-toggle-*' 'omarchy-once-*'` and
  renders the result.
- `toggle-run` starts a unit with `systemd-run --user`, clearing a previous
  failed state first so the same name can be reused.
- Saved commands are persisted through the shell's own settings IPC, so the
  running widget is patched in place and the popup stays open.

## License

MIT
