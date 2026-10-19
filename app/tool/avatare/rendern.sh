#!/usr/bin/env bash
# Rendert die SVG-Quellen (tool/avatare/svg) mit headless Chrome zu transparenten PNG (assets/avatare/, 256 x 256).
# Aufruf in app/: bash tool/avatare/rendern.sh   (CHROME=Pfad zur chrome.exe, falls nicht im Standardpfad)
set -euo pipefail
CHROME="${CHROME:-/c/Program Files/Google/Chrome/Application/chrome.exe}"
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
for f in tool/avatare/svg/*.svg; do
  base="$(basename "$f" .svg)"
  id="${base%%_*}"
  name="${base#*_}"
  svg="$(cat "$f")"
  printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}svg{display:block;width:256px;height:256px}</style>%s' "$svg" > "$tmp/$base.html"
  out="assets/avatare/avatar_${id}_${name}.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 --window-size=256,256 \
    --screenshot="$(cygpath -w "$PWD/$out")" "file:///$(cygpath -m "$tmp/$base.html")" >/dev/null 2>&1
  echo "$out"
done
rm -rf "$tmp"
