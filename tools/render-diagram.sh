#!/usr/bin/env bash
# tools/render-diagram.sh — render the README's architecture graph to
# docs/architecture.svg and stamp it with the hash of the source it came from.
#
# GitHub cannot render Graphviz, so the README shows a committed SVG and keeps
# the DOT as the reviewed artefact. That only works if the picture provably
# matches the source, hence the stamp: tools/check-diagram.sh recomputes the
# hash of the embedded DOT and fails when it does not match the stamp. Run this
# whenever you touch the diagram.
#
# Renderer, in order of preference: dot, then a @hpcc-js/wasm-graphviz copy
# under node_modules. There is no fallback — you cannot render without one.
#
# Exit 0 = rendered, 2 = no renderer available or bad input.
#
# Usage: tools/render-diagram.sh [markdown-file] [output-svg]
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${1:-$ROOT/README.md}"
OUT="${2:-$ROOT/docs/architecture.svg}"
[ -f "$DOC" ] || { echo "render-diagram.sh: not a file: $DOC" >&2; exit 2; }

DOT="$(mktemp)"; trap 'rm -f "$DOT"' EXIT
awk '
  /^[[:space:]]*```dot[[:space:]]*$/ { inb=1; n++; next }
  /^[[:space:]]*```[[:space:]]*$/    { if (inb) inb=0; next }
  inb { print }
  END { if (n==0) exit 3 }
' "$DOC" >"$DOT" || { echo "render-diagram.sh: no \`\`\`dot block in ${DOC#"$ROOT"/}" >&2; exit 2; }
[ -s "$DOT" ] || { echo "render-diagram.sh: empty \`\`\`dot block" >&2; exit 2; }

hash="$(sha256sum "$DOT" | cut -d' ' -f1)"
mkdir -p "$(dirname "$OUT")"

if command -v dot >/dev/null 2>&1; then
  engine=dot
  dot -Tsvg "$DOT" -o "$OUT"
else
  wasm=""
  for d in "$ROOT/node_modules" "$ROOT/tools/node_modules" "${NODE_PATH:-}" /tmp/node_modules; do
    [ -n "$d" ] && [ -f "$d/@hpcc-js/wasm-graphviz/dist/index.js" ] &&
      { wasm="$d/@hpcc-js/wasm-graphviz/dist/index.js"; break; }
  done
  [ -n "$wasm" ] && command -v node >/dev/null 2>&1 || {
    echo "render-diagram.sh: no renderer — install graphviz (dot) or @hpcc-js/wasm-graphviz" >&2
    exit 2
  }
  engine=wasm-graphviz
  node --input-type=module -e '
    import { readFileSync, writeFileSync } from "node:fs";
    const { Graphviz } = await import(process.argv[3]);
    const gv = await Graphviz.load();
    writeFileSync(process.argv[2], gv.layout(readFileSync(process.argv[1], "utf8"), "svg", "dot"));
  ' "$DOT" "$OUT" "$wasm"
fi

# Stamp the source hash so staleness is detectable without a renderer.
printf '<!-- diagram-source-sha256: %s -->\n' "$hash" >>"$OUT"

printf '✓ rendered %s (engine=%s, source sha256 %s)\n' \
  "${OUT#"$ROOT"/}" "$engine" "${hash:0:12}"
