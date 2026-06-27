#!/usr/bin/env bash
# Install this launcher package into the current user's home directory.
set -euo pipefail
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d "$HOME/bin" "$HOME/Desktop" "$HOME/.local/bin" "$HOME/.local/share/applications"

if [[ -d "$PKG/bin" ]]; then
  rsync -a "$PKG/bin/" "$HOME/bin/"
fi
if [[ -d "$PKG/.local/bin" ]]; then
  rsync -a "$PKG/.local/bin/" "$HOME/.local/bin/"
fi
if [[ -d "$PKG/icons" ]]; then
  install -d "$HOME/Pictures" "$HOME/.local/share/icons"
  rsync -a "$PKG/icons/" "$HOME/Pictures/"
  rsync -a "$PKG/icons/" "$HOME/.local/share/icons/"
fi

# Copy top-level scripts/dirs (network-reset.sh, intercept/, etc.)
for item in "$PKG"/*; do
  base="$(basename "$item")"
  case "$base" in
    bin|.local|desktop|icons|README.md|install.sh|.git|.gitignore) continue ;;
  esac
  if [[ -d "$item" ]]; then
    rsync -a --exclude='venv' --exclude='__pycache__' "$item/" "$HOME/$base/"
  elif [[ -f "$item" ]]; then
    cp -a "$item" "$HOME/$base"
    chmod +x "$HOME/$base" 2>/dev/null || true
  fi
done

for desktop in "$PKG"/desktop/*.desktop; do
  [[ -f "$desktop" ]] || continue
  name="$(basename "$desktop")"
  sed -e "s|/home/will|$HOME|g" "$desktop" >"$HOME/Desktop/$name"
  cp -a "$HOME/Desktop/$name" "$HOME/.local/share/applications/$name"
  chmod +x "$HOME/Desktop/$name" 2>/dev/null || true
done

echo "Installed to \$HOME/Desktop and \$HOME/bin (see README.md)"
