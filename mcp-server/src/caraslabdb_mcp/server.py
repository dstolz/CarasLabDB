"""CarasLabDB MCP server -- read-only tools over the `lab` Postgres schema.

Launched over stdio by Claude Code/Desktop. Connection settings come from
the standard libpq environment variables (see db.py); there is no server
config beyond that. All tools are SELECT-only: there is no
insert/update/delete surface, and db.py's read-only session +
transaction wrapper is the backstop if one is ever introduced by mistake.
"""

from mcp.server.fastmcp import FastMCP

from .tools import (
    artifacts, dimensions, events, health, provenance, reference, summary, tags, variables,
)

app = FastMCP("caraslabdb")

reference.register(app)
dimensions.register(app)
events.register(app)
artifacts.register(app)
provenance.register(app)
tags.register(app)
variables.register(app)
summary.register(app)
health.register(app)


def main():
    app.run()


if __name__ == "__main__":
    main()
