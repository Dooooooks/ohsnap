# OhSnap

Windows 11 style window snapping for [Omarchy](https://omarchy.org) floating workspaces.

On a workspace set to floating (Super + L, or Appearance > Workspace Layout), drag a
window by its titlebar (or with Super + left mouse):

| Drop it with the cursor at… | Result |
|---|---|
| Top edge | Maximize |
| Left or right edge | That half of the screen |
| Any corner | That quarter of the screen |

- An outline in your theme's accent colour shows where the window will land while you drag.
- Dragging a snapped window away gives it back its old size.
- Tiled workspaces are left alone.

## Requirements

- An Omarchy version that uses Hyprland's **Lua** config (`~/.config/hypr/hyprland.lua`)
  and has floating workspaces with titlebars.
- `python3` (for the optional release watcher), 64-bit system.

## Install

```bash
omarchy plugin add https://github.com/dooooooks/ohsnap.git --enable
~/.config/omarchy/plugins/dooooooks.ohsnap/install
```

`install` adds a small marked block to `~/.config/hypr/hyprland.lua` (saving a
`hyprland.lua.bak.<epoch>` first), makes sure the plugin is enabled, and reloads Hyprland.
Running it again changes nothing.

### Snap on release (optional)

Hyprland's titlebars swallow the mouse button, so on its own OhSnap notices a drop on
the first mouse movement after you let go. For an instant snap like Windows, `install`
offers to add you to the `input` group; a small watcher (`ohsnap-watch`, started by the
shell) then reads only the left button's release.

The trade-off: members of the `input` group can read raw keyboard and mouse input, so
any program you run could too. Answer no to keep things as they are; everything else
works the same. Log out and back in after joining the group.

Non-interactive: `./install --input-group` or `./install --no-input-group`.

## Tuning

Uncomment and edit the `ohsnap_config` line inside the OhSnap block in `hyprland.lua`:

```lua
ohsnap_config = {
  gap = 0,        -- px around snapped windows; default follows your gaps_out
  edge = 8,       -- px from a screen edge that counts as the edge
  corner = 120,   -- px from a corner that counts as the corner
}
```

The outline's look lives in `SnapPreview.qml`.

## Uninstall

```bash
~/.config/omarchy/plugins/dooooooks.ohsnap/uninstall
omarchy plugin remove dooooooks.ohsnap
sudo gpasswd -d "$USER" input   # only if you joined it for OhSnap
```

## How it works

- `ohsnap.lua` runs inside Hyprland. It watches the active floating window: while it
  moves in lockstep with the cursor it is being dragged, and the zone under the cursor
  decides the outline and where it snaps.
- `SnapPreview.qml` is an Omarchy shell service that draws the click-through outline
  (`omarchy-shell ohsnap show|hide`) and supervises `ohsnap-watch`.
- `ohsnap-watch` reads the left button's release from the mouse devices and calls
  `window_snap_release()` in Hyprland through `hyprctl eval`. It exits if it lacks
  permission, and OhSnap falls back to snapping on the next mouse movement.
