/* =============================================================================
   TITLE (READ-ONLY): Looker Under-Load Stress Profile - Looker SQL Patterns
   Part C of the stress profile toolkit.

   CONNECTIONS USED IN THIS FILE
     Part 1 -- redshift_pacific_time  (schema: atomic)
     Part 2 -- looker_mysql_direct    (schema: looker)
     Part 3 -- redshift_pacific_time  (schema: atomic)
   Switch connections in SQL Runner before running each part.

   *** STL RETENTION WARNING ***
   Redshift STL tables retain approximately 7 days of history.
   Run this file within 7 days of the target load period.

   PURPOSE
   Identifies the production query mix (Part 1) and extracts the actual SELECT
   statements the 4 target dashboards fired at Redshift (Parts 2 and 3). The
   SELECT patterns from Parts 2 and 3 are the templates for writing DAX measures
   in the Power BI load-test suite.

   NOTE ON TIER 3
   Part 1 shows a Tier 3 (>30s) bucket in the population mix. Analysis of that
   tier (Report C run May 21, 2026) showed it is dominated entirely by PDT
   rebuilds (INSERT INTO dev_looker.LR$...) scanning from 2023 start dates --
   not dashboard SELECT queries. Tier 3 runtime in the population mix is
   therefore not representative of dashboard load and is NOT used as a DAX
   template source.

   DAX LOAD TEST TIERS (based on dashboard SELECT patterns only)
     Tier 1 - Fast   (<10s)  : ~60% of firings  (volume, concurrent load)
     Tier 2 - Medium (10-30s): ~40% of firings  (moderately complex)
   Tier 3 WLM stress is simulated by widening the date range on a Tier 2
   query, not by replicating PDT rebuild SQL.

   HOW TO USE THIS FILE
   This file has three parts. Run each block separately in SQL Runner by
   highlighting the desired block and clicking Run. Note the connection switch
   between parts -- Part 2 runs on a different connection than Parts 1 and 3.

     PART 1 -- TIER SUMMARY                     (redshift_pacific_time)
       Overall query-count breakdown by runtime tier across all Looker
       traffic in the last 7 days. Confirms the production firing mix
       (e.g. 85% Tier 1 / 9% Tier 2 / 6% Tier 3) to calibrate the DAX
       load test schedule.

     PART 2 -- GET HISTORY SLUGS FOR 4 DASHBOARDS  (looker_mysql_direct)
       Queries the Looker MySQL history table to get the top 5 slowest
       history entries per dashboard for dashboards 13, 71, 103, and 120.
       Output: (dashboard_id, history_slug, runtime_seconds).
       Copy these slug values and paste them into Part 3.

     PART 3 -- DASHBOARD SELECT QUERIES BY SLUG    (redshift_pacific_time)
       Uses the slugs from Part 2 to retrieve the actual SELECT statements
       those 4 dashboards fired at Redshift. PDT rebuilds (INSERT INTO) are
       excluded. Output includes reconstructed SQL for DAX template design.

   NOTE ON LOOKER QUERY IDENTIFICATION
   Looker prepends a context comment to every query it sends to Redshift:
     -- Looker Query Context {"user_id":...,"history_slug":"<hash>",...}
   Parts 1 and 3 filter on querytxt ILIKE '%looker%' to identify this traffic.
   Part 3 additionally matches on the specific history_slug hash to isolate
   queries from the 4 target dashboards.

   ============================================================================= */


/* =============================================================================
   PART 1 -- TIER SUMMARY
   Run this block first. Highlight from WITH to the semicolon and click Run.
   ============================================================================= */

WITH config AS (
  SELECT
    DATEADD(day, -7, TRUNC(GETDATE()))  AS analysis_start,
    TRUNC(GETDATE())                     AS analysis_end
),

looker_queries AS (
  SELECT
    q.query                                                                   AS query_id,
    DATEDIFF(ms, q.starttime, q.endtime) / 1000.0                            AS runtime_seconds,
    CASE
      WHEN DATEDIFF(ms, q.starttime, q.endtime) / 1000.0 <  10 THEN 1
      WHEN DATEDIFF(ms, q.starttime, q.endtime) / 1000.0 <  30 THEN 2
      ELSE                                                          3
    END                                                                       AS tier_order,
    CASE
      WHEN DATEDIFF(ms, q.starttime, q.endtime) / 1000.0 <  10 THEN 'Tier 1 - Fast (<10s)'
      WHEN DATEDIFF(ms, q.starttime, q.endtime) / 1000.0 <  30 THEN 'Tier 2 - Medium (10-30s)'
      ELSE                                                          'Tier 3 - Heavy (>30s)'
    END                                                                       AS tier
  FROM stl_query q
  JOIN config c ON 1 = 1
  WHERE q.starttime >= c.analysis_start
    AND q.starttime <  c.analysis_end
    AND q.endtime IS NOT NULL
    AND q.querytxt ILIKE '%looker%'
),

tier_summary AS (
  SELECT
    tier,
    tier_order,
    COUNT(*)                                                                   AS query_count,
    ROUND(CAST(AVG(runtime_seconds) AS numeric(18,2)), 1)                     AS avg_runtime_seconds,
    ROUND(CAST(MAX(runtime_seconds) AS numeric(18,2)), 1)                     AS max_runtime_seconds
  FROM looker_queries
  GROUP BY tier, tier_order
)

SELECT result_section, key_value, metric_value, col_4, col_5
FROM (

  SELECT
    'REPORT_METADATA'                                                          AS result_section,
    'Analysis window'                                                          AS key_value,
    CAST(c.analysis_start AS VARCHAR) || ' to ' ||
    CAST(c.analysis_end   AS VARCHAR)                                          AS metric_value,
    NULL                                                                        AS col_4,
    NULL                                                                        AS col_5
  FROM config c

  UNION ALL

  SELECT
    'REPORT_METADATA'                                                          AS result_section,
    'Total Looker queries in window'                                            AS key_value,
    CAST(COUNT(*) AS VARCHAR)                                                  AS metric_value,
    NULL                                                                        AS col_4,
    NULL                                                                        AS col_5
  FROM looker_queries

  UNION ALL

  SELECT
    'REPORT_METADATA'                                                          AS result_section,
    'Note'                                                                     AS key_value,
    'Run Part 2 (looker_mysql_direct) to get slugs for dashboards 13/71/103/120, then Part 3 (redshift) to get their SQL' AS metric_value,
    NULL                                                                        AS col_4,
    NULL                                                                        AS col_5

  UNION ALL

  SELECT
    'TIER_SUMMARY_HEADINGS'                                                    AS result_section,
    'tier'                                                                     AS key_value,
    'query_count'                                                              AS metric_value,
    'avg_runtime_seconds'                                                       AS col_4,
    'max_runtime_seconds'                                                       AS col_5

  UNION ALL

  SELECT
    'TIER_SUMMARY'                                                             AS result_section,
    tier                                                                        AS key_value,
    CAST(query_count AS VARCHAR)                                               AS metric_value,
    CAST(avg_runtime_seconds AS VARCHAR)                                       AS col_4,
    CAST(max_runtime_seconds AS VARCHAR)                                       AS col_5
  FROM tier_summary

) sub
ORDER BY
  CASE result_section
    WHEN 'REPORT_METADATA'       THEN 1
    WHEN 'TIER_SUMMARY_HEADINGS' THEN 2
    WHEN 'TIER_SUMMARY'          THEN 3
    ELSE 9
  END,
  key_value;


/* =============================================================================
   PART 2 -- GET HISTORY SLUGS FOR THE 4 TARGET DASHBOARDS
   *** SWITCH CONNECTION TO: looker_mysql_direct  (schema: looker) ***

   Highlight from the first ( to the final semicolon and click Run.
   Returns the top 5 slowest history entries per dashboard over the last
   7 days for dashboards 13, 71, 103, and 120.

   OUTPUT COLUMNS
     dashboard_id    -- one of the 4 target dashboards
     history_slug    -- the slug embedded in Redshift context comments
     runtime_seconds -- end-to-end Looker render time for that execution
                        (NOTE: runtime column is in seconds in Looker history.
                        If your instance stores it in milliseconds, divide
                        by 1000 here and adjust the label accordingly.)

   AFTER RUNNING
   Copy each (history_slug, dashboard_id) pair from the results and paste
   them into the target_slugs VALUES placeholder in Part 3.
   Then switch back to redshift_pacific_time and run Part 3.
   ============================================================================= */

(
  SELECT 13 AS dashboard_id, h.slug AS history_slug, h.runtime AS runtime_seconds
  FROM looker.history h
  WHERE h.dashboard_id  = 13
    AND h.completed_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    AND h.slug IS NOT NULL
    AND h.slug        != ''
  ORDER BY h.runtime DESC
  LIMIT 5
)
UNION ALL
(
  SELECT 71 AS dashboard_id, h.slug AS history_slug, h.runtime AS runtime_seconds
  FROM looker.history h
  WHERE h.dashboard_id  = 71
    AND h.completed_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    AND h.slug IS NOT NULL
    AND h.slug        != ''
  ORDER BY h.runtime DESC
  LIMIT 5
)
UNION ALL
(
  SELECT 103 AS dashboard_id, h.slug AS history_slug, h.runtime AS runtime_seconds
  FROM looker.history h
  WHERE h.dashboard_id  = 103
    AND h.completed_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    AND h.slug IS NOT NULL
    AND h.slug        != ''
  ORDER BY h.runtime DESC
  LIMIT 5
)
UNION ALL
(
  SELECT 120 AS dashboard_id, h.slug AS history_slug, h.runtime AS runtime_seconds
  FROM looker.history h
  WHERE h.dashboard_id  = 120
    AND h.completed_at >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    AND h.slug IS NOT NULL
    AND h.slug        != ''
  ORDER BY h.runtime DESC
  LIMIT 5
)
ORDER BY dashboard_id, runtime_seconds DESC;


/* =============================================================================
   PART 3 -- DASHBOARD SELECT QUERIES VIA SLUG FILTER
   *** SWITCH CONNECTION TO: redshift_pacific_time  (schema: atomic) ***

   Highlight from WITH to the semicolon and click Run.
   Finds the actual SELECT statements those 4 dashboards fired at Redshift,
   matched by the history_slug Looker embeds in every query context comment.
   PDT rebuilds (INSERT INTO, CREATE) are excluded so only dashboard-driven
   SELECT queries are returned.

   BEFORE RUNNING
   1. Run Part 2 on looker_mysql_direct to get the slug list.
   2. Replace the placeholder rows in the target_slugs VALUES block below
      with the actual (slug, dashboard_id) pairs from Part 2 output.
      Format for each row:  ('the_32char_slug_hash', 13),

   OUTPUT COLUMNS
     dashboard_id    -- which of the 4 dashboards fired this query
     history_slug    -- cross-reference with Part 2 to confirm dashboard
     runtime_seconds -- Redshift execution time
     run_date        -- Pacific date
     run_hour        -- Pacific hour (compare against peak hours from Report A)
     sql_text        -- first 2000 chars of the SELECT statement
                        (scan FROM, JOIN, WHERE, GROUP BY for DAX template design)
   ============================================================================= */

WITH target_slugs AS (
  /* -------------------------------------------------------------------
     PASTE SLUGS HERE
     Replace or add UNION ALL SELECT rows below with real values from Part 2.
     One row per slug. Redshift does not support VALUES(...) AS t(col, col)
     syntax reliably, so UNION ALL SELECT is used instead.
     ------------------------------------------------------------------- */
  -- Dashboard 13 (top 5 slowest renders, 180-269s end-to-end)
  SELECT 'bdbb0f5c6dd34ca3ccf8b4a707c8a768' AS slug, 13 AS dashboard_id
  UNION ALL SELECT '108598c1f8d823ccd82c1ca26652c29e', 13
  UNION ALL SELECT '9b41fd7785b36610a41c576e4a862f45', 13
  UNION ALL SELECT '01e7d387f4f6634194cd6c756e1ee1f5', 13
  UNION ALL SELECT '122466c299ecb4f4956a7e488c95d9e6', 13
  -- Dashboard 71 (15 most recent sessions, 2026-05-22T22:30 -- run same day as Part 3)
  UNION ALL SELECT '74dddec596924ff68e2eb25dc3bc919c', 71
  UNION ALL SELECT '0e3df31a4490f02b2e4a62a956866fd2', 71
  UNION ALL SELECT 'eecc0cae2ed669b2f58d49e5ad0b4314', 71
  UNION ALL SELECT '209f9aaaff2823043470e633374d6852', 71
  UNION ALL SELECT '2d14f3692c49f54a827fab6df6694d03', 71
  UNION ALL SELECT 'f26b4fa11d70c67565f72a6649e7d950', 71
  UNION ALL SELECT 'ed2452f5250d01f19079e34954d3d04c', 71
  UNION ALL SELECT '3305070039ac6d9ebdcb561c56cc3be3', 71
  UNION ALL SELECT 'debb3be64d8b2bb78852fc778c2a996c', 71
  UNION ALL SELECT '7c4445f50bf738b0c8f168dd1dad45c6', 71
  UNION ALL SELECT '52443eecd9da31c38c3567497498feff', 71
  UNION ALL SELECT 'bdd5c8a94e3eb7dff1f4edab5a90d4ff', 71
  UNION ALL SELECT 'd0c6a08886ec1976cbb07cb778fcda28', 71
  UNION ALL SELECT '9a4a55696296b14c36086253f03eeda0', 71
  UNION ALL SELECT 'a753b14a84bd67f003da853d18f1899f', 71
  -- Dashboard 103 (top 5 slowest renders, 501-551s end-to-end)
  UNION ALL SELECT '764d191a823965d214ebd43d97f15caf', 103
  UNION ALL SELECT '350e602872d7da677a3ba3ba3a214d67', 103
  UNION ALL SELECT '5b79153f7a5878b58120324623e513e9', 103
  UNION ALL SELECT 'b00764c3e67bde7690c07c74b4d10624', 103
  UNION ALL SELECT 'ab7ec344805f0e7bcc671682e4fc69d1', 103
  -- Dashboard 120 (top 5 slowest renders, 56-96s end-to-end)
  UNION ALL SELECT 'acf4f2cbaa6895d4577ee4afe9bc493d', 120
  UNION ALL SELECT 'b603815ee81c60e4d212837ae22dc55a', 120
  UNION ALL SELECT '40c1e30d45f29662ec5883e29d526a16', 120
  UNION ALL SELECT 'aff9b8a8fe33d4960316cce71f7cb951', 120
  UNION ALL SELECT '9b5040a4749116c99123400579ddb3b8', 120
),

config AS (
  SELECT
    DATEADD(day, -7, TRUNC(GETDATE()))  AS analysis_start,
    TRUNC(GETDATE())                     AS analysis_end
),

looker_select_queries AS (
  SELECT
    q.query                                                                    AS query_id,
    q.starttime,
    DATEDIFF(ms, q.starttime, q.endtime) / 1000.0                             AS runtime_seconds,
    ts.dashboard_id,
    ts.slug                                                                    AS history_slug
  FROM stl_query q
  JOIN config c ON 1 = 1
  JOIN target_slugs ts
    ON q.querytxt ILIKE '%"history_slug":"' || ts.slug || '"%'
  WHERE q.starttime  >= c.analysis_start
    AND q.starttime   < c.analysis_end
    AND q.endtime    IS NOT NULL
    AND q.querytxt NOT ILIKE 'INSERT INTO%'
    AND q.querytxt NOT ILIKE 'CREATE %'
    AND q.querytxt NOT ILIKE 'SET %'
),

query_text AS (
  SELECT
    t.query,
    LISTAGG(t.text, '') WITHIN GROUP (ORDER BY t.sequence)                    AS full_sql
  FROM stl_querytext t
  WHERE t.query IN (SELECT query_id FROM looker_select_queries)
  GROUP BY t.query
)

SELECT
  lsq.dashboard_id,
  lsq.history_slug,
  ROUND(CAST(lsq.runtime_seconds AS numeric(18,2)), 2)                       AS runtime_seconds,
  DATE(CONVERT_TIMEZONE('UTC', 'America/Vancouver', lsq.starttime))          AS run_date,
  EXTRACT(hour FROM CONVERT_TIMEZONE('UTC', 'America/Vancouver',
          lsq.starttime))                                                     AS run_hour,
  LEFT(qt.full_sql, 2000)                                                    AS sql_text
FROM looker_select_queries lsq
LEFT JOIN query_text qt ON lsq.query_id = qt.query
ORDER BY lsq.dashboard_id, lsq.runtime_seconds DESC;
