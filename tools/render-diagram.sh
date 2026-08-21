#!/usr/bin/env bash
# tools/render-diagram.sh — render docs/diagrams/*.dot to sibling .svg files and
# stamp each with the hash of the source it came from.
#
# GitHub cannot render Graphviz, so the README shows committed SVGs and keeps
# the DOT as the reviewed artefact. That only works if each picture provably
# matches its source, hence the stamp: tools/check-diagram.sh recomputes the
# hash of the DOT and fails when it does not match. Run this whenever you touch
# a diagram.
#
# Each source produces TWO files: <name>.svg for light backgrounds and
# <name>.dark.svg for dark ones, and the README serves them through a <picture>
# element so GitHub picks by theme. The dark copy is derived from the light one
# by mapping the palette — Graphviz emits no fill attribute on <text> at all, so
# the labels inherit SVG's black default and are invisible against a dark page
# until the injected stylesheet recolours them. Keep the two in sync by editing
# only the .dot and re-running this script; never hand-edit an SVG.
#
# Renderer, in order of preference: dot, then a @hpcc-js/wasm-graphviz copy
# under node_modules. There is no fallback — you cannot render without one.
#
# Exit 0 = rendered, 2 = no renderer available or bad input.
#
# Usage:
#   tools/render-diagram.sh                  # every docs/diagrams/*.dot
#   tools/render-diagram.sh <file.dot> ...   # only those files
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGRAMS="$ROOT/docs/diagrams"

if [ "$#" -gt 0 ]; then
  SOURCES=("$@")
else
  SOURCES=()
  while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$DIAGRAMS" -maxdepth 1 -name '*.dot' | sort)
fi
[ "${#SOURCES[@]}" -gt 0 ] || {
  echo "render-diagram.sh: no .dot files found under ${DIAGRAMS#"$ROOT"/}" >&2; exit 2; }

# ------------------------------------------------------------------ renderer
engine=""
wasm=""
if command -v dot >/dev/null 2>&1; then
  engine=dot
else
  for d in "$ROOT/node_modules" "$ROOT/tools/node_modules" "${NODE_PATH:-}" /tmp/node_modules; do
    [ -n "$d" ] && [ -f "$d/@hpcc-js/wasm-graphviz/dist/index.js" ] &&
      { wasm="$d/@hpcc-js/wasm-graphviz/dist/index.js"; break; }
  done
  if [ -n "$wasm" ] && command -v node >/dev/null 2>&1; then
    engine=wasm-graphviz
  else
    echo "render-diagram.sh: no renderer — install graphviz (dot) or @hpcc-js/wasm-graphviz" >&2
    exit 2
  fi
fi

render_one() {
  local src="$1" out="$2"
  if [ "$engine" = dot ]; then
    dot -Tsvg "$src" -o "$out"
  else
    node --input-type=module -e '
      import { readFileSync, writeFileSync } from "node:fs";
      const { Graphviz } = await import(process.argv[3]);
      const gv = await Graphviz.load();
      writeFileSync(process.argv[2],
        gv.layout(readFileSync(process.argv[1], "utf8"), "svg", "dot"));
    ' "$src" "$out" "$wasm"
  fi
}

# Derive the dark copy from the light one. The palette is small and fixed by
# the .dot files, so a literal colour map is both sufficient and reviewable;
# anything not in the map is left alone rather than guessed at.
make_dark() {
  python3 - "$1" "$2" <<'PY'
import re, sys

MAP = {
    # panel and node fills: light surface -> dark surface
    "#ffffff": "#161b22",  # default node
    "#f6f8fa": "#1c2128",  # neutral panel / node
    "#fff8c5": "#33290a",  # amber "this caused an outage"
    "#ddf4ff": "#0d2438",  # blue delivery
    "#dafbe1": "#0f2417",  # green Ottawa
    "#dbeafe": "#10233b",  # indigo Robbinsdale
    "#ffe3ea": "#2d1519",  # red St. Petersburg
    "#ece9fd": "#1e1940",  # purple tailnet
    "#fff1e5": "#2a1a0f",  # orange outside world
    "#eef7ff": "#0f1d2e",
    "#f5f0ff": "#1c1633",
    "#fffbe6": "#1e1b09",  # large panel: keep it darker than the node tint
                           # above, or it reads as the brightest thing on the
                           # page purely because of its area
    "#f0fff4": "#0e2015",
    "#fff5f7": "#2a141a",
    "#eef4fb": "#111e2e",
    "#f0f6ff": "#0f1a2b",
    # strokes and arrowheads: darken-for-light -> brighten-for-dark
    "#57606a": "#8b949e",  # default edge
    "#8c959f": "#6e7681",  # default node border
    "#d0d7de": "#30363d",
    "#9a6700": "#d29922",
    "#1a7f37": "#3fb950",
    "#a40e26": "#f85149",
    "#0550ae": "#58a6ff",
    "#0969da": "#58a6ff",
    "#bc4c00": "#db6d28",
    "#8250df": "#a371f7",
}

svg = open(sys.argv[1], encoding="utf-8").read()
svg = re.sub(r"#[0-9a-fA-F]{6}",
             lambda m: MAP.get(m.group(0).lower(), m.group(0)), svg)

# Graphviz writes no fill on <text>, so it falls back to black. Recolour the
# labels, and paint the canvas so the file is also readable opened on its own.
style = ('<style type="text/css">'
         'svg{background:#0d1117}'
         'text{fill:#e6edf3}'
         '</style>')
svg = re.sub(r"(<svg\b[^>]*>)", r"\1\n" + style, svg, count=1)
open(sys.argv[2], "w", encoding="utf-8").write(svg)
PY
}

for src in "${SOURCES[@]}"; do
  [ -f "$src" ] || { echo "render-diagram.sh: not a file: $src" >&2; exit 2; }
  out="${src%.dot}.svg"
  dark="${src%.dot}.dark.svg"
  hash="$(sha256sum "$src" | cut -d' ' -f1)"
  mkdir -p "$(dirname "$out")"

  render_one "$src" "$out"
  make_dark "$out" "$dark"

  # Stamp the source hash so staleness is detectable without a renderer.
  printf '<!-- diagram-source-sha256: %s -->\n' "$hash" >>"$out"
  printf '<!-- diagram-source-sha256: %s -->\n' "$hash" >>"$dark"

  printf '✓ rendered %s and %s (engine=%s, source sha256 %s)\n' \
    "${out#"$ROOT"/}" "${dark##*/}" "$engine" "${hash:0:12}"
done
