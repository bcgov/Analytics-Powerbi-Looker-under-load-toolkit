/* =============================================================================
   DIAGNOSTIC — Redshift stl_query / stl_wlm_query data availability check
   CONNECTION: redshift_pacific_time
   SCHEMA:     atomic

   Run each numbered block separately in SQL Runner to diagnose why
   A_1_full_report_B_redshift_stl_queries.sql returns no data.
   ============================================================================= */


/* ---------------------------------------------------------------------------
   CHECK 1: Is there ANY data in stl_query at all?
   Expected: a row count > 0 and a recent max_starttime
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)                        AS total_rows,
  MIN(starttime)                  AS earliest_starttime,
  MAX(starttime)                  AS latest_starttime
FROM stl_query;


/* ---------------------------------------------------------------------------
   CHECK 2: Is there ANY data in stl_wlm_query at all?
   Expected: a row count > 0
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)                        AS total_rows,
  MIN(service_class_start_time)   AS earliest,
  MAX(service_class_start_time)   AS latest
FROM stl_wlm_query;


/* ---------------------------------------------------------------------------
   CHECK 3: Does stl_query have rows in the April 2026 date range?
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)                        AS rows_in_april_2026
FROM stl_query
WHERE starttime >= '2026-04-01'
  AND starttime <  '2026-05-01';


/* ---------------------------------------------------------------------------
   CHECK 4: Sample 10 querytxt values from April 2026 — what do they look like?
   This tells us whether 'looker' appears in the query text at all.
   --------------------------------------------------------------------------- */
SELECT
  query,
  userid,
  LEFT(querytxt, 120)             AS querytxt_sample,
  starttime
FROM stl_query
WHERE starttime >= '2026-04-01'
  AND starttime <  '2026-05-01'
ORDER BY starttime DESC
LIMIT 10;


/* ---------------------------------------------------------------------------
   CHECK 5: Does 'looker' appear anywhere in querytxt?
   If count = 0, the ILIKE '%looker%' filter is the problem.
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)                        AS rows_with_looker_in_text
FROM stl_query
WHERE starttime >= '2026-04-01'
  AND starttime <  '2026-05-01'
  AND querytxt ILIKE '%looker%';


/* ---------------------------------------------------------------------------
   CHECK 6: What userids / usernames ran queries in April 2026?
   Looker typically connects as a specific DB user — look for a service account.
   --------------------------------------------------------------------------- */
SELECT
  userid,
  COUNT(*)                        AS query_count
FROM stl_query
WHERE starttime >= '2026-04-01'
  AND starttime <  '2026-05-01'
GROUP BY userid
ORDER BY query_count DESC
LIMIT 20;


/* ---------------------------------------------------------------------------
   CHECK 7: Does SVL_QLOG exist and does it have older data?
   svl_qlog is a view that sometimes retains more history than stl_query.
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)          AS total_rows,
  MIN(starttime)    AS earliest,
  MAX(starttime)    AS latest
FROM svl_qlog;


/* ---------------------------------------------------------------------------
   CHECK 8: Does SYS_QUERY_HISTORY exist?
   Available on RA3 / Redshift Serverless clusters — retains up to 35 days.
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)          AS total_rows,
  MIN(start_time)   AS earliest,
  MAX(start_time)   AS latest
FROM sys_query_history;


/* ---------------------------------------------------------------------------
   CHECK 9: Is there an admin schema with audit/query log tables?
   Common pattern: DBAs create a persistent query log via unload + reload.
   --------------------------------------------------------------------------- */
SELECT
  table_schema,
  table_name,
  table_type
FROM information_schema.tables
WHERE LOWER(table_name) LIKE '%query%'
   OR LOWER(table_name) LIKE '%audit%'
   OR LOWER(table_name) LIKE '%log%'
ORDER BY table_schema, table_name;


/* ---------------------------------------------------------------------------
   CHECK 10: Any tables in the public / admin / reporting schemas worth noting?
   --------------------------------------------------------------------------- */
SELECT
  table_schema,
  table_name
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema', 'pg_catalog', 'pg_internal')
  AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name
LIMIT 50;


/* ---------------------------------------------------------------------------
   CHECK 11: Does pg_catalog.stl_query differ from atomic.stl_query?
   Some clusters alias differently; check earliest row via catalog directly.
   --------------------------------------------------------------------------- */
SELECT
  COUNT(*)          AS total_rows,
  MIN(starttime)    AS earliest,
  MAX(starttime)    AS latest
FROM pg_catalog.stl_query;

