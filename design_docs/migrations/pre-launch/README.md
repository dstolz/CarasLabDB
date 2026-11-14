# Pre-launch migrations (archived)

These files are the upgrade history of the database before it was launched.
They are kept for the record. Nothing applies or tests them.

Before launch the schema was numbered differently. The first version had no
`lab.schema_version` table, and these scripts took it to version 5. The schema
they produce is the one `design_docs/schema.sql` installs, renamed
**version 1** for the launch. A database upgraded with these scripts reports
version 5, and the clients (`CarasLabDB.SchemaVersionExpected`, the MCP
server's `db.SCHEMA_VERSION`) refuse it as a mismatch. Install the launch
database from `schema.sql` instead.

| File | What it was |
| --- | --- |
| `002_integrity_hardening.sql` | pre-launch version 2 |
| `003_tags.sql` | pre-launch version 3: tags |
| `004_access_and_correction_hardening.sql` | pre-launch version 4 |
| `005_variables_retraction_logins.sql` | pre-launch version 5: variables, retraction, logins |
| `seed_v1.sql` | a small dataset in the first pre-launch schema, for testing the upgrades on a database that holds rows |
| `migrated_data_test.sql` | assertions on that dataset after every upgrade |

The paths inside these files (`design_docs/migrations/`, `tests/seed_v1.sql`,
`tests/migrated_data_test.sql`, `SCHEMA_V1_COMMIT`) are where they lived while
they were in use.

Migrations made after launch go in `design_docs/migrations/` and are numbered
from `002`.
