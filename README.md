# Retile

An Omarchy overlay plugin. Lays the current workspace's windows out as draggable
tiles, then applies the arrangement with `hyprctl`.

- Drag a tile to move it. Dropping onto another tile swaps them, or pushes it to
  the nearest open space. Tiles never overlap.
- Pull a tile's bottom-right corner to resize.
- `C` columns, `R` rows, `G` grid presets
- `Enter` apply (windows are floated at the chosen positions)
- `T` hand every window back to the tiling layout
- `Esc` cancel

## Install

Copy this folder to `~/.config/omarchy/plugins/jmramsay.retile`, add
`{ "id": "jmramsay.retile" }` to `plugins` in `~/.config/omarchy/shell.json`, and
bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + R", "Retile windows", "omarchy-shell shell toggle jmramsay.retile")
```

Tested on Hyprland 0.56.2.
