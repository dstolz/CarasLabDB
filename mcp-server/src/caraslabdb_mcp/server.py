"""CarasLabDB MCP server -- read-only tools over the `lab` Postgres schema.

Launched over stdio by Claude Code/Desktop. Connection settings come from
the standard libpq environment variables (see db.py); there is no server
config beyond that. All tools are SELECT-only (see db.py's READ ONLY
transaction wrapper) -- there is no insert/update/delete surface in v1.
"""

from mcp.server.fastmcp import FastMCP

from .tools import artifacts, dimensions, events, provenance, reference

app = FastMCP("caraslabdb")

reference.register(app)
dimensions.register(app)
events.register(app)
artifacts.register(app)
provenance.register(app)


def main():
    app.run()


if __name__ == "__main__":
    main()
