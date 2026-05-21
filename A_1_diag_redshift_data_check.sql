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
   CHECK 7: Sample querytxt from the highest-volume userid
   Replace <userid> with the top userid from CHECK 6.
   --------------------------------------------------------------------------- */
-- SELECT LEFT(querytxt, 200) AS sample, starttime
-- FROM stl_query
-- WHERE userid = <userid>
--   AND starttime >= '2026-04-01'
--   AND starttime <  '2026-05-01'
-- ORDER BY starttime DESC
-- LIMIT 10;
