#!/usr/bin/env bash
# Load every CloudNativePG image-volume extension into the Cluster's exact
# operand image and run CREATE EXTENSION, so an extension built against a newer
# PostgreSQL minor (undefined symbol at load time) fails CI instead of the
# Database CR in the cluster. Needs docker.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

# shellcheck source=SCRIPTDIR/lib/pyyaml.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib/pyyaml.sh"

PLATFORM="${CNPG_EXT_PLATFORM:-linux/amd64}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import json
import pathlib
import sys

import yaml

work = pathlib.Path(sys.argv[1])
cases = []
for path in sorted(pathlib.Path("kubernetes").rglob("*.yaml")):
    if ".sops." in path.name:
        continue
    try:
        docs = [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    except yaml.YAMLError:
        continue
    for doc in docs:
        if doc.get("apiVersion", "").split("/")[0] != "postgresql.cnpg.io" or doc.get("kind") != "Cluster":
            continue
        pg = doc.get("spec", {}).get("postgresql", {}) or {}
        exts = pg.get("extensions") or []
        if not exts:
            continue
        image = doc["spec"].get("imageName")
        name = doc["metadata"]["name"]
        where = f"{path}:{name}"
        if not image:
            raise SystemExit(f"{where}: extensions need an explicit spec.imageName to pin the PostgreSQL minor")
        refs = [e.get("image", {}).get("reference", "") for e in exts]
        if "${" in image or any("${" in r for r in refs):
            print(f"skip {where}: Flux substitution in image references", file=sys.stderr)
            continue
        sql = []
        for sibling in sorted(path.parent.glob("*.yaml")):
            for d in yaml.safe_load_all(sibling.read_text()):
                if (
                    isinstance(d, dict)
                    and d.get("kind") == "Database"
                    and d.get("spec", {}).get("cluster", {}).get("name") == name
                ):
                    sql += [
                        x["name"]
                        for x in d["spec"].get("extensions") or []
                        if x.get("ensure", "present") == "present"
                    ]
        mounts, control, libs = [], ["$system"], ["$libdir"]
        for e in exts:
            base = f"/extensions/{e['name']}"
            mounts.append({"name": e["name"], "ref": e["image"]["reference"]})
            control += [f"{base}/{p}" for p in e.get("extension_control_path") or ["share"]]
            libs += [f"{base}/{p}" for p in e.get("dynamic_library_path") or ["lib"]]
        params = {str(k): str(v) for k, v in (pg.get("parameters") or {}).items()}
        params["extension_control_path"] = ":".join(control)
        params["dynamic_library_path"] = ":".join(libs)
        if pg.get("shared_preload_libraries"):
            params["shared_preload_libraries"] = ",".join(pg["shared_preload_libraries"])
        case = work / f"case{len(cases)}"
        case.mkdir()
        (case / "extra.conf").write_text(
            "".join(f"{k} = '{v.replace(chr(39), chr(39) * 2)}'\n" for k, v in params.items())
        )
        (case / "check.sql").write_text(
            "".join(f'CREATE EXTENSION IF NOT EXISTS "{s}";\n' for s in sql)
            + "SELECT extname || ' ' || extversion FROM pg_extension ORDER BY 1;\n"
        )
        cases.append({"dir": str(case), "where": where, "image": image, "mounts": mounts})
(work / "cases.json").write_text(json.dumps(cases))
PY

count="$(jq length "$WORK/cases.json")"
[ "$count" -gt 0 ] || { echo "✓ cnpg extensions: no Cluster declares image-volume extensions"; exit 0; }

fail=0
for i in $(seq 0 $((count - 1))); do
  c="$(jq -c ".[$i]" "$WORK/cases.json")"
  dir="$(jq -r .dir <<<"$c")"
  where="$(jq -r .where <<<"$c")"
  image="$(jq -r .image <<<"$c")"
  vols=()
  while IFS=$'\t' read -r ename ref; do
    docker pull -q --platform "$PLATFORM" "$ref" >/dev/null
    cid="$(docker create --platform "$PLATFORM" "$ref" x)"
    mkdir -p "$dir/ext/$ename"
    docker cp -q "$cid:/" "$dir/ext/$ename"
    docker rm -f "$cid" >/dev/null
    chmod -R a+rX "$dir/ext/$ename"
    vols+=(-v "$dir/ext/$ename:/extensions/$ename:ro")
  done < <(jq -r '.mounts[] | [.name, .ref] | @tsv' <<<"$c")
  chmod a+r "$dir/extra.conf" "$dir/check.sql"
  docker pull -q --platform "$PLATFORM" "$image" >/dev/null
  if out="$(docker run --rm --platform "$PLATFORM" --entrypoint bash \
      -v "$dir/extra.conf:/check/extra.conf:ro" -v "$dir/check.sql:/check/check.sql:ro" "${vols[@]}" \
      "$image" -c '
        set -e
        export PGDATA=/tmp/pgdata
        initdb -U postgres -A trust >/dev/null
        cat /check/extra.conf >> "$PGDATA/postgresql.conf"
        pg_ctl -w -l /tmp/pg.log -o "-c listen_addresses= -k /tmp" start >/dev/null || { cat /tmp/pg.log; exit 1; }
        psql -X -v ON_ERROR_STOP=1 -h /tmp -U postgres -Atf /check/check.sql || { tail -5 /tmp/pg.log; exit 1; }
      ' 2>&1)"; then
    echo "✓ $where: $(tr '\n' ',' <<<"$out" | sed 's/,$//') on $image"
  else
    echo "✗ $where on $image" >&2
    tail -20 <<<"$out" >&2
    fail=1
  fi
done
exit "$fail"
