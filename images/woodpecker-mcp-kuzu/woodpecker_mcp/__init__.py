"""woodpecker-mcp - a materialized service dependency graph as an MCP toolset.

HolmesGPT (and similar agents) *infer* service relationships on the fly from
telemetry and discard them after each investigation. woodpecker-mcp instead
**materializes** the dependency graph in a graph database (FalkorDB by default)
so it can be queried deterministically and explored independently:

  - deepest-failing-service root cause (a single Cypher query)
  - blast radius (variable-length path traversal)
  - observability blind-spot detection

Exposed to any MCP client over stdio or HTTP.
"""
__version__ = "0.2.0"
