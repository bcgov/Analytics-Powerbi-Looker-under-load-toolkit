/* =============================================================================
   TITLE (READ-ONLY): Looker Under-Load Stress Profile - Redshift Dimensions
   Companion to: A_1_full_report_A_looker_history_queries.sql

   CONNECTION: redshift_pacific_time
   SCHEMA:     atomic   (stl_query and stl_wlm_query live here)
   Run in SQL Runner on the redshift_pacific_time connection with schema set to atomic.

   *** STL RETENTION WARNING ***
   Redshift STL tables (stl_query, stl_wlm_query) retain approximately 7 days
   of history. This report is SELF-CONTAINED and analyses the last 7 days
   automatically - no input from A_1_full_report_A_looker_history_queries.sql
   is required. Run this file promptly after a load event; data older than
   ~7 days is permanently lost from STL tables.

   PURPOSE
   Covers the Redshift-side dimensions of the stress profile that cannot be
   queried from the Looker history table:

     DIMENSION 7 - WLM Queue Time
       Measures how long Looker queries waited in Redshift WLM queues during
       peak hours. Establishes the admission-pressure baseline that Power BI
       load will need to account for.

     DIMENSION 8 - Redshift CPU Saturation
       Measures Redshift CPU utilisation during peak dashboard hours.
       Establishes headroom (or lack thereof) available to absorb the Power BI
       workload alongside the existing Looker load.

   ============================================================================= */

/* READ-ONLY QUERY
   This SQL is strictly read-only and does not modify any database objects. */

/* ---------------------------------------------------------------------------
   OPTIONAL TUNING
   By default the report covers the last 7 days and detects peak hours from
   ALL queries in stl_query. If your Looker service account has a known
   username, set looker_username below to restrict peak-hour detection to
   Looker traffic only. Leave as NULL to use all queries.

   To find the Looker userid run:
     SELECT usesysid, usename FROM pg_user ORDER BY usename;
   and look for a service-account name (e.g. 'looker', 'svc_looker').
   Set looker_userid to that integer value to restrict peak-hour detection
   to Looker traffic only. Leave as NULL to use all queries.
   --------------------------------------------------------------------------- */

WITH config AS (
  SELECT
    DATEADD(day, -7, TRUNC(GETDATE()))  AS analysis_start,
    TRUNC(GETDATE())                     AS analysis_end,
    NULL::INTEGER                        AS looker_userid   -- set e.g. 42 to filter by Looker service account
),

/* =============================================================================
   PEAK HOUR DETECTION
   Mirrors A_1_full_report_A_looker_history_queries.sql logic:
   for each calendar day (Pacific time), the peak hour is the one with the
   highest total elapsed query time.
   ============================================================================= */

hourly_load AS (
  SELECT
    DATE(CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime))           AS query_date_pacific,
    EXTRACT(hour FROM CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime)) AS query_hour_pacific,
    SUM(DATEDIFF(ms, q.starttime, q.endtime))                                  AS total_elapsed_ms
  FROM stl_query q
  JOIN config c ON 1 = 1
  WHERE q.starttime >= c.analysis_start
    AND q.starttime <  c.analysis_end
    AND q.endtime IS NOT NULL
    AND (c.looker_userid IS NULL OR q.userid = c.looker_userid)
  GROUP BY 1, 2
),

daily_max_load AS (
  SELECT
    query_date_pacific,
    MAX(total_elapsed_ms) AS max_elapsed_ms
  FROM hourly_load
  GROUP BY query_date_pacific
),

peak_hours AS (
  SELECT
    h.query_date_pacific                AS completed_date_pacific,
    MIN(h.query_hour_pacific)           AS completed_hour_pacific
  FROM hourly_load h
  JOIN daily_max_load dm
    ON h.query_date_pacific = dm.query_date_pacific
   AND h.total_elapsed_ms   = dm.max_elapsed_ms
  GROUP BY h.query_date_pacific
),

/* =============================================================================
   DIMENSION 7 - WLM QUEUE TIME CTEs
   ============================================================================= */

d7_peak_hour_wlm AS (
  SELECT
    ph.completed_date_pacific             AS peak_date_pacific,
    ph.completed_hour_pacific             AS peak_hour_pacific,
    w.service_class,
    w.total_queue_time,
    w.total_exec_time
  FROM stl_wlm_query w
  JOIN stl_query q
    ON w.query = q.query
  JOIN peak_hours ph
    ON DATE(CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime))              = ph.completed_date_pacific
   AND EXTRACT(hour FROM CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime)) = ph.completed_hour_pacific
  WHERE q.endtime IS NOT NULL
),

d7_wlm_summary AS (
  SELECT
    w.service_class,
    COUNT(*)                                                              AS total_queries,
    COUNT(CASE WHEN w.total_queue_time > 0 THEN 1 END)                   AS queued_queries,
    ROUND(
      100.0 * COUNT(CASE WHEN w.total_queue_time > 0 THEN 1 END)
            / NULLIF(COUNT(*), 0),
      1
    )                                                                     AS pct_queries_queued,
    ROUND(
      CAST(AVG(w.total_queue_time) / 1000000.0 AS numeric(18,2)),
      2
    )                                                                     AS avg_queue_time_seconds,
    ROUND(
      CAST(MAX(w.total_queue_time) / 1000000.0 AS numeric(18,2)),
      2
    )                                                                     AS max_queue_time_seconds,
    ROUND(
      CAST(AVG(w.total_exec_time)  / 1000000.0 AS numeric(18,2)),
      2
    )                                                                     AS avg_exec_time_seconds
  FROM d7_peak_hour_wlm w
  GROUP BY w.service_class
),

/* =============================================================================
   DIMENSION 8 - CPU SATURATION CTEs
   Reuses config and peak_hours from above.
   exec_fraction_of_total_time: ratio of execution time to (queue + exec) time.
     Near 1.0 = CPU-bound (executing; little WLM headroom to absorb PBI load)
     Near 0.0 = queue-bound (queries waiting for admission, not CPU)
   ============================================================================= */

d8_peak_hour_exec AS (
  SELECT
    ph.completed_date_pacific   AS peak_date_pacific,
    ph.completed_hour_pacific   AS peak_hour_pacific,
    w.total_queue_time,
    w.total_exec_time
  FROM stl_wlm_query w
  JOIN stl_query q
    ON w.query = q.query
  JOIN peak_hours ph
    ON DATE(CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime))              = ph.completed_date_pacific
   AND EXTRACT(hour FROM CONVERT_TIMEZONE('UTC', 'America/Vancouver', q.starttime)) = ph.completed_hour_pacific
  JOIN config c ON 1 = 1
  WHERE q.starttime >= c.analysis_start
    AND q.starttime <  c.analysis_end
    AND q.endtime IS NOT NULL
),

d8_cpu_summary AS (
  SELECT
    peak_date_pacific,
    peak_hour_pacific,
    COUNT(*)                                                                       AS total_queries,
    ROUND(CAST(AVG(total_exec_time)  / 1000000.0 AS numeric(18,2)), 2)            AS avg_exec_time_seconds,
    ROUND(CAST(AVG(total_queue_time) / 1000000.0 AS numeric(18,2)), 2)            AS avg_queue_time_seconds,
    ROUND(
      CAST(AVG(total_exec_time) AS numeric(18,6))
        / NULLIF(CAST(AVG(total_queue_time + total_exec_time) AS numeric(18,6)), 0),
      2
    )                                                                              AS exec_fraction_of_total_time
  FROM d8_peak_hour_exec
  GROUP BY peak_date_pacific, peak_hour_pacific
)

/* =============================================================================
   FINAL SINGLE RESULT SET (REPORT FORMAT)
   5-column output to match A_1_full_report_A_looker_history_queries.sql
   result_section | key_value | metric_value | col_4 | col_5
   ============================================================================= */

SELECT result_section, key_value, metric_value, col_4, col_5
FROM (

/* --- REPORT METADATA --- */
SELECT
  'REPORT_METADATA'                                          AS result_section,
  'Analysis window'                                          AS key_value,
  CAST(c.analysis_start AS VARCHAR) || ' to ' ||
  CAST(c.analysis_end   AS VARCHAR)                          AS metric_value,
  NULL                                                        AS col_4,
  NULL                                                        AS col_5
FROM config c

UNION ALL

SELECT
  'REPORT_METADATA'                                          AS result_section,
  'STL retention warning'                                    AS key_value,
  'STL tables retain ~7 days only - run promptly after load events' AS metric_value,
  NULL                                                        AS col_4,
  NULL                                                        AS col_5

UNION ALL

SELECT
  'REPORT_METADATA'                                          AS result_section,
  'Peak hours detected'                                      AS key_value,
  CAST(COUNT(*) AS VARCHAR)                                  AS metric_value,
  NULL                                                        AS col_4,
  NULL                                                        AS col_5
FROM peak_hours

UNION ALL

/* --- DIMENSION 7: COLUMN HEADINGS --- */
SELECT
  'D7_COLUMN_HEADINGS'        AS result_section,
  'service_class'             AS key_value,
  'pct_queries_queued'        AS metric_value,
  'avg_queue_time_seconds'    AS col_4,
  'max_queue_time_seconds'    AS col_5

UNION ALL

/* --- DIMENSION 7: WLM QUEUE DATA (aggregated across all peak hours) --- */
SELECT
  'D7_WLM_QUEUE'                              AS result_section,
  CAST(s.service_class AS VARCHAR)            AS key_value,
  CAST(s.pct_queries_queued AS VARCHAR)       AS metric_value,
  CAST(s.avg_queue_time_seconds AS VARCHAR)   AS col_4,
  CAST(s.max_queue_time_seconds AS VARCHAR)   AS col_5
FROM d7_wlm_summary s

UNION ALL

/* --- DIMENSION 7: EXEC TIME CONTEXT (avg exec time vs avg queue time) --- */
SELECT
  'D7_WLM_EXEC'                               AS result_section,
  CAST(s.service_class AS VARCHAR)            AS key_value,
  CAST(s.avg_exec_time_seconds AS VARCHAR)    AS metric_value,
  CAST(s.queued_queries AS VARCHAR)           AS col_4,
  CAST(s.total_queries AS VARCHAR)            AS col_5
FROM d7_wlm_summary s

UNION ALL

/* --- DIMENSION 8: COLUMN HEADINGS --- */
SELECT
  'D8_COLUMN_HEADINGS'        AS result_section,
  'peak_date'                 AS key_value,
  'exec_fraction_of_total'    AS metric_value,
  'avg_exec_time_seconds'     AS col_4,
  'avg_queue_time_seconds'    AS col_5

UNION ALL

/* --- DIMENSION 8: CPU SATURATION PROXY (per peak day, all WLM traffic) --- */
SELECT
  'D8_CPU_SATURATION'                                        AS result_section,
  CAST(s.peak_date_pacific AS VARCHAR)                       AS key_value,
  CAST(s.exec_fraction_of_total_time AS VARCHAR)             AS metric_value,
  CAST(s.avg_exec_time_seconds AS VARCHAR)                   AS col_4,
  CAST(s.avg_queue_time_seconds AS VARCHAR)                  AS col_5
FROM d8_cpu_summary s

) sub
ORDER BY
  CASE result_section
    WHEN 'REPORT_METADATA'    THEN 1
    WHEN 'D7_COLUMN_HEADINGS' THEN 2
    WHEN 'D7_WLM_QUEUE'       THEN 3
    WHEN 'D7_WLM_EXEC'        THEN 4
    WHEN 'D8_COLUMN_HEADINGS' THEN 5
    WHEN 'D8_CPU_SATURATION'  THEN 6
    ELSE 9
  END,
  key_value;

