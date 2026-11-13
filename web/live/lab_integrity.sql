-- ============================================================================
-- lab_integrity.sql — a summary of lab.fn_check_integrity() for the live
-- dashboard's Integrity panel.
-- ============================================================================
-- Emits a SINGLE row / SINGLE column of JSON:
--
--   { "computed_at": "...Z",
--     "example_limit": 20,
--     "checks": [ { "severity": "error"|"warning", "check_name": "...",
--                   "count": <rows the check returned>,
--                   "examples": [ {"subject": "...", "detail": "..."}, ... ] } ] }
--
-- One entry per check that returned anything, errors first, then by name.
-- `examples` holds at most example_limit rows of the check (ordered by
-- subject, detail): the full result can be one row per artifact, which is
-- not something to ship to a browser. An empty `checks` array means healthy.
--
-- On a large database fn_check_integrity() costs about as much as the whole
-- lab_data.sql export, so server.py runs this on its own, longer-lived cache
-- (INTEGRITY_CACHE_SECONDS) and adds the result to the payload as
-- `integrity`; it is kept out of lab_data.sql for that reason. Standalone:
--   PGTZ=UTC psql -tAXq -v ON_ERROR_STOP=1 -d lab -f web/live/lab_integrity.sql
-- This file is a single statement.
-- ============================================================================

SELECT json_build_object(
    'computed_at',   to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'example_limit', 20,
    'checks', coalesce((
        SELECT json_agg(json_build_object(
                   'severity', g.severity, 'check_name', g.check_name,
                   'count', g.n, 'examples', g.examples)
               ORDER BY (g.severity = 'error') DESC, g.check_name)
        FROM (
            SELECT x.severity, x.check_name, count(*) AS n,
                   coalesce(json_agg(json_build_object('subject', x.subject, 'detail', x.detail)
                                     ORDER BY x.subject, x.detail)
                            FILTER (WHERE x.rn <= 20), '[]'::json) AS examples
            FROM (
                SELECT f.severity, f.check_name, f.subject, f.detail,
                       row_number() OVER (PARTITION BY f.severity, f.check_name
                                          ORDER BY f.subject, f.detail) AS rn
                FROM lab.fn_check_integrity() f
            ) x
            GROUP BY x.severity, x.check_name
        ) g
    ), '[]'::json)
) AS lab_integrity;
