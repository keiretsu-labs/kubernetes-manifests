"""woodpecker-mcp CLI.

  woodpecker-mcp init [--defaults] [--force]       # guided .env (--defaults = template)
  woodpecker-mcp setup [--config PATH] [--no-falkordb] [--no-config]   # start FalkorDB + wire into HolmesGPT
  woodpecker-mcp serve [--http] [--host 0.0.0.0] [--port 8000]   # MCP server (stdio default)
  woodpecker-mcp refresh                          # rebuild the graph from live sources
  woodpecker-mcp ingest <file.json>               # load a static topology (offline study)
  woodpecker-mcp diagnose                          # refresh + print root-cause analysis
  woodpecker-mcp topology                          # refresh + print the service graph

Config via env or a .env file: WP_GRAPH_BACKEND, WP_FALKOR_HOST, WP_TOPOLOGY,
WP_PROM_URL, WP_AUTO_REFRESH (0 = static snapshot). See docs/CONFIGURATION.md.
"""
import json
import os
import sys

from . import build, config
from .diagnose import diagnose
from .store import open_store


def _flag_value(argv, flag, default):
    """Value following `flag` in argv, or `default`. Exits 2 on a dangling flag."""
    if flag not in argv:
        return default
    i = argv.index(flag)
    if i + 1 >= len(argv):
        print(f"error: {flag} requires a value", file=sys.stderr)
        raise SystemExit(2)
    return argv[i + 1]


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd = argv[0] if argv else "serve"

    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0

    if cmd == "serve":
        from .server import run
        http = "--http" in argv
        try:
            port = int(_flag_value(argv, "--port", "8000"))
        except ValueError:
            print("error: --port must be an integer", file=sys.stderr)
            return 2
        host = _flag_value(argv, "--host", config.HTTP_HOST)
        run(transport="http" if http else "stdio", host=host, port=port)
        return 0

    if cmd == "init":
        from .scaffold import interactive_env, write_env
        force = "--force" in argv
        if "--defaults" in argv or "-y" in argv:
            print(write_env(".env", force=force))
        else:
            print(interactive_env(".env", force=force))
        return 0

    if cmd == "setup":
        from .scaffold import (falkordb_status_line, patch_holmes_config,
                               start_falkordb, write_env)
        if not os.path.exists(".env"):
            print(write_env(".env"))
        if config.GRAPH_BACKEND == "falkordb":
            if "--no-falkordb" not in argv:
                print(start_falkordb())
            print(falkordb_status_line(config.FALKOR_HOST, config.FALKOR_PORT, config.FALKOR_PASSWORD))
        if "--no-config" in argv:
            print("skipped HolmesGPT config patch (--no-config); attach the toolset yourself with -t")
        else:
            cfg = argv[argv.index("--config") + 1] if "--config" in argv else "~/.holmes/config.yaml"
            print(patch_holmes_config(cfg))
            print('Done. Run:  holmes ask "find the root cause of the current incident"')
        return 0

    if cmd == "ingest":
        if len(argv) < 2:
            print("usage: woodpecker-mcp ingest <file.json>", file=sys.stderr)
            return 2
        with open(argv[1]) as f:
            data = json.load(f)
        build.ingest_static(open_store(), data)
        print(f"ingested {len(data.get('services', []))} services into the {config.GRAPH_BACKEND} graph")
        return 0

    store = open_store()
    warnings = []
    if cmd in ("refresh", "topology", "diagnose") and config.AUTO_REFRESH:
        warnings = build.refresh(store)
        for w in warnings:
            print(f"warning: {w}", file=sys.stderr)
    if cmd == "refresh":
        print(f"refreshed the {config.GRAPH_BACKEND} graph"
              if config.AUTO_REFRESH else "WP_AUTO_REFRESH=0 - nothing refreshed")
    elif cmd == "topology":
        print(json.dumps({"services": store.topology()}, indent=2))
    elif cmd == "diagnose":
        from .snapshot import maybe_save
        print(json.dumps(maybe_save(diagnose(store, warnings=warnings), store), indent=2))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
