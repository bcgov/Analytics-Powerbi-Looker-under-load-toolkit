/* =============================================================================
   TITLE (READ-ONLY): Looker Under-Load Stress Profile - Looker SQL Patterns
   Part C of the stress profile toolkit.

   CONNECTION: redshift_pacific_time
   SCHEMA:     atomic   (stl_query and stl_querytext live here)
   Run in SQL Runner on the redshift_pacific_time connection with schema set to atomic.

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
   This file has two parts. Run each block separately in SQL Runner by
   highlighting the desired block and clicking Run.

     PART 1 -- TIER SUMMARY
       Metadata and query-count breakdown by tier.
       Use this to confirm the tier distribution before pulling full SQL.

     PART 2 -- QUERY DETAIL
       Top 5 slowest queries per tier with reconstructed SQL text.
       Use this to identify base tables, join complexity, and filter patterns
       for writing equivalent DAX measures.

   NOTE ON LOOKER QUERY IDENTIFICATION
   Looker prepends a context comment to every query it sends to Redshift:
     -- Looker Query Context {"user_id":..., "history_id":...}
   This file filters on querytxt ILIKE '%looker%' to identify Looker traffic.
   If your environment uses a different tagging convention, adjust the filter.

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
    'Run Part 2 to retrieve reconstructed SQL text for the top 5 queries per tier' AS metric_value,
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
   PART 2 -- QUERY DETAIL
   Run this block separately. Highlight from WITH to the semicolon and click Run.
   Returns the top 5 slowest queries per tier with reconstructed SQL text.

   COLUMNS
     tier               -- Tier 1/2/3 label
     rank_in_tier       -- 1 = slowest in that tier
     query_id           -- Redshift query ID (cross-reference with stl_wlm_query)
     runtime_seconds    -- total execution time
     run_date           -- Pacific date the query ran
     run_hour           -- Pacific hour the query ran (for peak-hour context)
     sql_text           -- first 2000 chars of reconstructed SQL
                           (look for FROM, JOIN, WHERE to identify tables
                           and filter patterns for DAX template design)
   ============================================================================= */

WITH config AS (
  SELECT
    DATEADD(day, -7, TRUNC(GETDATE()))  AS analysis_start,
    TRUNC(GETDATE())                     AS analysis_end
),

looker_queries AS (
  SELECT
    q.query                                                                   AS query_id,
    q.starttime,
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

query_text AS (
  SELECT
    t.query,
    LISTAGG(t.text, '') WITHIN GROUP (ORDER BY t.sequence)                    AS full_sql
  FROM stl_querytext t
  WHERE t.query IN (SELECT query_id FROM looker_queries)
  GROUP BY t.query
),

ranked AS (
  SELECT
    lq.tier,
    lq.tier_order,
    lq.query_id,
    ROUND(CAST(lq.runtime_seconds AS numeric(18,2)), 2)                       AS runtime_seconds,
    DATE(CONVERT_TIMEZONE('UTC', 'America/Vancouver', lq.starttime))          AS run_date,
    EXTRACT(hour FROM CONVERT_TIMEZONE('UTC', 'America/Vancouver',
            lq.starttime))                                                     AS run_hour,
    LEFT(qt.full_sql, 2000)                                                   AS sql_text,
    ROW_NUMBER() OVER (
      PARTITION BY lq.tier_order
      ORDER BY lq.runtime_seconds DESC
    )                                                                          AS rank_in_tier
  FROM looker_queries lq
  LEFT JOIN query_text qt ON lq.query_id = qt.query
)

SELECT
  tier,
  rank_in_tier,
  query_id,
  runtime_seconds,
  run_date,
  run_hour,
  sql_text
FROM ranked
WHERE rank_in_tier <= 5
ORDER BY tier_order, rank_in_tier;
