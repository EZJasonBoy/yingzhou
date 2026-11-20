#!/bin/sh
# Puts 映舟 in your application menu, from wherever this folder was unpacked (no root needed):
#
#   ./install-desktop-entry.sh            # add the menu entry and icons for this user
#   ./install-desktop-entry.sh --remove   # take them away again
#
# Only the menu entry and icons go to ~/.local/share; the app stays in this folder. Run it again after moving the
# folder. Not needed with the .deb, which installs its own entry.
set -eu
id=io.github.sa1koro.yingzhou
here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
entry="$data/applications/$id.desktop"

if [ "${1:-}" = "--remove" ]; then
  rm -f "$entry"
  find "$data/icons/hicolor" -name "$id.*" -delete 2>/dev/null || true
  echo "removed $entry"
else
  mkdir -p "$data/applications" "$data/icons"
  # Exec points into this folder, quoted by the desktop file's rules: \ " ` $ escaped inside the quotes, and every
  # backslash doubled again because the value is a string.
  exe=$(printf '%s' "$here/yingzhou" | sed 's/[\\"`$]/\\\\&/g')
  while IFS= read -r line; do
    case "$line" in
      Exec=*) printf 'Exec="%s"\n' "$exe" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$here/share/applications/$id.desktop" > "$entry"
  cp -R "$here/share/icons/hicolor" "$data/icons/"
  echo "added $entry"
fi
# Menus notice the change by themselves; these only make it quicker.
update-desktop-database "$data/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t "$data/icons/hicolor" >/dev/null 2>&1 || true
