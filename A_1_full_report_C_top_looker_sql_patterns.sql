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
   Extracts and reconstructs the actual SQL that Looker fired at Redshift
   during the past 7 days, grouped into three runtime tiers. These query
   patterns are the templates for writing DAX measures in the Power BI
   load-test suite.

   The three tiers map directly to the DAX query firing schedule:
     Tier 1 - Fast   (<10s)  : ~60% of firings  (volume, concurrent load)
     Tier 2 - Medium (10-30s): ~30% of firings  (moderately complex)
     Tier 3 - Heavy  (>30s)  : ~10% of firings  (tail queries, WLM stress)

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
  WHERE h.real_dash_id  = 13
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
  WHERE h.real_dash_id  = 71
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
  WHERE h.real_dash_id  = 103
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
  WHERE h.real_dash_id  = 120
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
     Replace the two placeholder rows below with real values from Part 2.
     One row per slug. Add or remove rows as needed.
     Example rows:
       ('e2efad2aa12bde310f53456cd1668a32', 13),
       ('a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4', 71),
       ('f9e8d7c6b5a4f9e8d7c6b5a4f9e8d7c6', 103),
       ('1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d', 120)
     ------------------------------------------------------------------- */
  SELECT slug, dashboard_id FROM (VALUES
    ('REPLACE_ME_slug_1', 13),
    ('REPLACE_ME_slug_2', 71)
  ) AS t(slug, dashboard_id)
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
