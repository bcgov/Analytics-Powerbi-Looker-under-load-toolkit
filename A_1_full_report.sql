/* =============================================================================
   A_1 — FULL STRESS PROFILE AND DAX RECOMMENDATIONS REPORT (READ-ONLY)

   PURPOSE

   - Turns Looker history into quantified system stress profile
   - And then can be used to create a concrete DAX simulation plan
   
   STRUCTURE

   - Is self-documented (purpose + read*only note at top)
   - Is broken into stress dimensions (each with purpose + outputs + commented SQL)
   - Includes intermediate sanity*check outputs
   - Ends with a structured meta*output that tells you exactly what DAX workload to simulate

   Scope

   - Dashboard*generated queries only (history.dashboard_id IS NOT NULL)
   - One peak hour per day (hour with max dashboard runtime)
   ============================================================================= */

/* READ-ONLY QUERIES

   This SQL is strictly read*only. It only SELECTs and aggregates existing data
   and does NOT insert, update, delete, or modify any database objects. */

/* *************************************************************************
   INPUT

   * Run this query in SQL Runner
   * Connection: looker_mysql_direct
   * Schema: looker
   * Table: history

   The history table records every query executed by Looker, including timing,
   runtime, dashboard attribution, user, session, and cache information.
    *************************************************************************** */

/* ==========================================================================
    DIMENSION 1. DAILY PEAKS

    Summarizes daily peak *interactive dashboard* behavior across an extended
    period and presents the results as a self*describing report.
    *************************************************************************** */

/* ***************************************************************************
   OUTPUTS

   The result set contains a single, self*describing report organized into
   labeled sections via the `result_section` column. Each row represents a
   specific metric, distribution element, or explanatory note.

   Columns

   * result_section : Logical grouping or metric identifier
   * key_value      : Dimension, label, or identifier (for example hour or dashboard_id)
   * metric_value   : Numeric value or descriptive text associated with the row

   Sections included:

   1. REPORT_METADATA
      - Analysis date range
      - Number of daily peak hours analyzed (one per day)
      - Count of distinct dashboards participating in peak hours
      - Explanatory notes for interpreting later sections

   2. A_PEAK_HOUR_DISTRIBUTION
      - Distribution of peak hour*of*day (Pacific Time)
      - Shows how often each hour is identified as the daily peak

   3. B_PEAK_RUNTIME (Peak Hour Runtime Magnitude)
      - P50, P75, P90, and MAX of total dashboard runtime (seconds)
        during each day’s peak hour
      - Represents intensity of interactive load during peak periods

   4. C_DASHBOARD_*_RECURRENCE (Peak Driver Identification)
      - Dashboards grouped by frequency of appearance in daily peak hours:
          - CORE (>= 75% of days)
          - STRUCTURAL (>= 50% of days)
          - FREQUENT (>= 25% of days)
      - Identifies which dashboards consistently drive peak load

   Interpretation Notes:

   - Each day contributes exactly one peak hour
   - Runtime is the sum of query runtimes for dashboard*generated queries only
   - Results are designed to support downstream workload modeling,
     including concurrency estimation and representative dashboard selection

   *************************************************************************** */


WITH date_range AS (
  SELECT
    '2026-01-05' AS analysis_range_first_day,
    '2026-04-26' AS analysis_range_last_day
),

/* ***************************************************************************
   D0.1 — DAYS WITH DATA IN RANGE (CTE)
   *************************************************************************** */
d0_days_data AS (
  SELECT
    COUNT(DISTINCT
      /* AND h.runtime IS NOT NULL: excludes phantom Saturday sessions where
         dashboard_id is set but runtime is NULL (likely scheduled content
         deliveries). Diagnostic confirmed 6 Saturdays each with 1–3 NULL-runtime
         queries — not interactive usage days. Without this, those days are
         counted here but silently dropped by daily_peak_hours, causing a
         discrepancy in REPORT_METADATA. */
      CASE WHEN h.dashboard_id IS NOT NULL
            AND h.runtime IS NOT NULL
           THEN DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
      END
    ) AS distinct_days_dashboard_queries,
    COUNT(DISTINCT
      DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
    ) AS distinct_days_any_query
  FROM history h
  JOIN date_range dr ON 1=1
  WHERE CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
    AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
),

/* ***************************************************************************
   IDENTIFY DAILY PEAK DASHBOARD HOUR (PACIFIC TIME)
   *************************************************************************** */
   
daily_peak_hours AS (
  SELECT
    hourly.completed_date_pacific,
    MIN(hourly.completed_hour_pacific) AS peak_hour_pacific
  FROM (
    SELECT
      DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        AS completed_date_pacific,
      HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        AS completed_hour_pacific,
      SUM(h.runtime) AS hourly_dashboard_runtime
    FROM history h
    JOIN date_range dr ON 1=1
    WHERE CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
      AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
      AND h.dashboard_id IS NOT NULL
      /* AND h.runtime IS NOT NULL: excludes phantom Saturday sessions where
         dashboard_id is set but runtime is NULL (likely scheduled content
         deliveries). Without this filter, SUM(runtime) = NULL for those hours,
         MAX(hourly_dashboard_runtime) = NULL, and the JOIN condition
         (NULL = NULL) never matches, silently dropping those days. */
      AND h.runtime IS NOT NULL
    GROUP BY 1,2
  ) hourly
  JOIN (
    SELECT
      completed_date_pacific,
      MAX(hourly_dashboard_runtime) AS max_runtime
    FROM (
      SELECT
        DATE(CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver'))
          AS completed_date_pacific,
        HOUR(CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver'))
          AS completed_hour_pacific,
        SUM(h2.runtime) AS hourly_dashboard_runtime
      FROM history h2
      JOIN date_range dr2 ON 1=1
      WHERE CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            >= dr2.analysis_range_first_day
        AND CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            <  dr2.analysis_range_last_day
        AND h2.dashboard_id IS NOT NULL
        AND h2.runtime IS NOT NULL  -- same NULL-runtime exclusion as outer subquery
      GROUP BY 1,2
    ) x
    GROUP BY completed_date_pacific
  ) mx
    ON hourly.completed_date_pacific = mx.completed_date_pacific
   AND hourly.hourly_dashboard_runtime = mx.max_runtime
  GROUP BY completed_date_pacific
),

/* ***************************************************************************
   DAILY PEAK HOUR RUNTIME MAGNITUDE
   *************************************************************************** */
daily_peak_magnitude AS (
  SELECT
    ph.completed_date_pacific,
    ph.peak_hour_pacific,
    SUM(h.runtime) AS peak_hour_runtime
  FROM daily_peak_hours ph
  JOIN history h
    ON DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.completed_date_pacific
   AND HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.peak_hour_pacific
  WHERE h.dashboard_id IS NOT NULL
  GROUP BY 1,2
),

/* ***************************************************************************
   DASHBOARD PARTICIPATION IN DAILY PEAK HOURS
   *************************************************************************** */
dashboard_peak_participation AS (
  SELECT DISTINCT
    ph.completed_date_pacific,
    h.dashboard_id
  FROM daily_peak_hours ph
  JOIN history h
    ON DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.completed_date_pacific
   AND HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.peak_hour_pacific
  WHERE h.dashboard_id IS NOT NULL
),

/* ***************************************************************************
   RANK PEAK RUNTIMES (MYSQL 5.7 SAFE — NO WINDOW FUNCTIONS)
   *************************************************************************** */
ranked_peaks AS (
  SELECT
    peak_hour_runtime,
    @rn := @rn + 1 AS rn,
    @total := @total AS total_rows
  FROM (
    SELECT peak_hour_runtime
    FROM daily_peak_magnitude
    ORDER BY peak_hour_runtime
  ) ordered
  CROSS JOIN (SELECT @rn := 0) r
  CROSS JOIN (SELECT @total := COUNT(*) FROM daily_peak_magnitude) t
),

/* ***************************************************************************
   DIMENSION 2 — QUERY RATE CTEs
   Source: A_1_query3_looker_queries_rate.sql
   *************************************************************************** */

d2_peak_hours AS (
  SELECT
    hourly.completed_date_pacific,
    MIN(hourly.completed_hour_pacific) AS completed_hour_pacific
  FROM (
    SELECT
      DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        AS completed_date_pacific,
      HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        AS completed_hour_pacific,
      SUM(h.runtime) AS hourly_dashboard_runtime
    FROM history h
    JOIN date_range dr ON 1=1
    WHERE CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
      AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
      AND h.dashboard_id IS NOT NULL
      AND h.runtime IS NOT NULL
    GROUP BY completed_date_pacific, completed_hour_pacific
  ) hourly
  JOIN (
    SELECT
      x.completed_date_pacific,
      MAX(x.hourly_dashboard_runtime) AS max_runtime
    FROM (
      SELECT
        DATE(CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver'))
          AS completed_date_pacific,
        HOUR(CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver'))
          AS completed_hour_pacific,
        SUM(h2.runtime) AS hourly_dashboard_runtime
      FROM history h2
      JOIN date_range dr2 ON 1=1
      WHERE CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            >= dr2.analysis_range_first_day
        AND CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            <  dr2.analysis_range_last_day
        AND h2.dashboard_id IS NOT NULL
        AND h2.runtime IS NOT NULL
      GROUP BY completed_date_pacific, completed_hour_pacific
    ) x
    GROUP BY x.completed_date_pacific
  ) mx
    ON hourly.completed_date_pacific  = mx.completed_date_pacific
   AND hourly.hourly_dashboard_runtime = mx.max_runtime
  GROUP BY hourly.completed_date_pacific
),

d2_classified_queries AS (
  SELECT
    CASE
      WHEN h.dashboard_id IS NOT NULL THEN 'Dashboard-Only Queries'
      ELSE 'Non-Dashboard Queries'
    END AS query_category,
    CASE
      WHEN ph.completed_date_pacific IS NOT NULL
       AND HOUR(CONVERT_TZ(h.created_at,'UTC','America/Vancouver'))
           = ph.completed_hour_pacific
      THEN 'Peak-Hours'
      ELSE 'All-Hours'
    END AS time_scope,
    h.created_at
  FROM history h
  LEFT JOIN d2_peak_hours ph
    ON DATE(CONVERT_TZ(h.created_at,'UTC','America/Vancouver'))
       = ph.completed_date_pacific
  JOIN date_range dr ON 1=1
  WHERE CONVERT_TZ(h.created_at,'UTC','America/Vancouver')
        >= dr.analysis_range_first_day
    AND CONVERT_TZ(h.created_at,'UTC','America/Vancouver')
        <  dr.analysis_range_last_day
),

d2_queries_per_minute AS (
  SELECT
    cq.time_scope,
    cq.query_category,
    COUNT(*) AS queries_started_in_minute
  FROM d2_classified_queries cq
  GROUP BY
    cq.time_scope,
    cq.query_category,
    DATE(CONVERT_TZ(cq.created_at,'UTC','America/Vancouver')),
    HOUR(CONVERT_TZ(cq.created_at,'UTC','America/Vancouver')),
    MINUTE(CONVERT_TZ(cq.created_at,'UTC','America/Vancouver'))
),

d2_base_metrics AS (
  SELECT
    qpm.time_scope,
    qpm.query_category,
    AVG(qpm.queries_started_in_minute) AS baseline_queries_per_minute,
    MAX(qpm.queries_started_in_minute) AS max_queries_per_minute,
    COUNT(*)                            AS total_minutes
  FROM d2_queries_per_minute qpm
  GROUP BY qpm.time_scope, qpm.query_category
)

/* ***************************************************************************
   FINAL SINGLE RESULT SET (REPORT FORMAT)
   *************************************************************************** */

/* --- REPORT METADATA --- */
SELECT result_section, key_value, metric_value, NULL AS col_4, NULL AS col_5
FROM (

SELECT
  'REPORT_METADATA' AS result_section,
  'Date range' AS key_value,
  CONCAT(
    (SELECT analysis_range_first_day FROM date_range),
    ' to ',
    (SELECT analysis_range_last_day FROM date_range)
  ) AS metric_value

UNION ALL
SELECT
  'REPORT_METADATA',
  'Number of days in date range',
  DATEDIFF(
    (SELECT analysis_range_last_day FROM date_range),
    (SELECT analysis_range_first_day FROM date_range)
  )

UNION ALL
SELECT
  'REPORT_METADATA',
  'Days with any queries',
  distinct_days_any_query
FROM d0_days_data

UNION ALL
SELECT
  'REPORT_METADATA',
  'Days with dashboard queries',
  distinct_days_dashboard_queries
FROM d0_days_data

UNION ALL
SELECT
  'REPORT_METADATA',
  'Days with no dashboard queries',
  distinct_days_any_query - distinct_days_dashboard_queries
FROM d0_days_data

UNION ALL
SELECT
  'REPORT_METADATA',
  'Total daily peak hours analysed',
  (SELECT COUNT(*) FROM daily_peak_hours)

UNION ALL
/* If this value is non-zero, some days had dashboard queries but were silently
   dropped by the daily_peak_hours CTE. Known hypotheses:
   (a) Tie in hourly runtime across two or more hours on the same day — the
       MAX(hourly_dashboard_runtime) join matches multiple hours, and the
       GROUP BY / MIN(hour) may not resolve cleanly in all MySQL versions.
   (b) Queries completed exactly at the date boundary (midnight Pacific) causing
       a date mismatch between the outer filter and the inner subquery.
   (c) A dashboard_id that is NOT NULL but evaluates as a zero-runtime session,
       meaning it appears in d0_days_data but produces no hourly_dashboard_runtime
       row in the peak-hours subquery. */
SELECT
  'REPORT_METADATA',
  'Days with dashboard queries but no identified peak hour (expect 0)',
  distinct_days_dashboard_queries - (SELECT COUNT(*) FROM daily_peak_hours)
FROM d0_days_data

UNION ALL
SELECT
  'REPORT_METADATA',
  'Number of distinct dashboards appearing in daily peak hours',
  (SELECT COUNT(DISTINCT dashboard_id) FROM dashboard_peak_participation)

/* --- PEAK HOUR DISTRIBUTION --- */
UNION ALL
SELECT
  'A_PEAK_HOUR_DISTRIBUTION',
  CAST(peak_hour_pacific AS CHAR),
  COUNT(*)
FROM daily_peak_hours
GROUP BY peak_hour_pacific


/* *** SECTION B METADATA (EXPLAINER) *** */
UNION ALL
SELECT
  'REPORT_METADATA',
  'Peak runtime magnitude distribution',
  'For each day, total interactive dashboard runtime during that day’s single peak hour; percentiles summarize the distribution of these daily peak values.'


/* --- PEAK RUNTIME MAGNITUDE --- */
UNION ALL
SELECT
  'B_PEAK_RUNTIME_P50',
  'p50_seconds',
  MIN(peak_hour_runtime)
FROM ranked_peaks
WHERE rn >= CEILING(0.50 * total_rows)

UNION ALL
SELECT
  'B_PEAK_RUNTIME_P75',
  'p75_seconds',
  MIN(peak_hour_runtime)
FROM ranked_peaks
WHERE rn >= CEILING(0.75 * total_rows)

UNION ALL
SELECT
  'B_PEAK_RUNTIME_P90',
  'p90_seconds',
  MIN(peak_hour_runtime)
FROM ranked_peaks
WHERE rn >= CEILING(0.90 * total_rows)

UNION ALL
SELECT
  'B_PEAK_RUNTIME_MAX',
  'max_seconds',
  MAX(peak_hour_runtime)
FROM daily_peak_magnitude


/* --- RECURRENCE — CORE TIER HEADER --- */
UNION ALL
SELECT
  'REPORT_NOTE',
  'Dashboards driving peak usage — dashboards present in at least 75% of daily peak hours',
  NULL

UNION ALL
SELECT
  'C_DASHBOARD_CORE_RECURRENCE_GE_75PCT',
  CAST(dashboard_id AS CHAR),
  COUNT(DISTINCT completed_date_pacific)
FROM dashboard_peak_participation
GROUP BY dashboard_id
HAVING COUNT(DISTINCT completed_date_pacific)
       >= 0.75 * (SELECT COUNT(*) FROM daily_peak_hours)

UNION ALL
SELECT
  'C_DASHBOARD_CORE_RECURRENCE_GE_75PCT',
  'None',
  0
FROM (SELECT 1) AS dummy
WHERE NOT EXISTS (
  SELECT 1
  FROM dashboard_peak_participation
  GROUP BY dashboard_id
  HAVING COUNT(DISTINCT completed_date_pacific)
         >= 0.75 * (SELECT COUNT(*) FROM daily_peak_hours)
)


/* --- RECURRENCE — STRUCTURAL TIER HEADER --- */
UNION ALL
SELECT
  'REPORT_NOTE',
  'Dashboards driving peak usage — dashboards present in at least 50% of daily peak hours',
  NULL

UNION ALL
SELECT
  'C_DASHBOARD_STRUCTURAL_RECURRENCE_GE_50PCT',
  CAST(dashboard_id AS CHAR),
  COUNT(DISTINCT completed_date_pacific)
FROM dashboard_peak_participation
GROUP BY dashboard_id
HAVING COUNT(DISTINCT completed_date_pacific)
       >= 0.5 * (SELECT COUNT(*) FROM daily_peak_hours)


/* --- RECURRENCE — FREQUENT TIER HEADER --- */
UNION ALL
SELECT
  'REPORT_NOTE',
  'Dashboards driving peak usage — dashboards present in at least 25% of daily peak hours',
  NULL

UNION ALL
SELECT
  'C_DASHBOARD_FREQUENT_RECURRENCE_GE_25PCT',
  CAST(dashboard_id AS CHAR),
  COUNT(DISTINCT completed_date_pacific)
FROM dashboard_peak_participation
GROUP BY dashboard_id
HAVING COUNT(DISTINCT completed_date_pacific)
       >= 0.25 * (SELECT COUNT(*) FROM daily_peak_hours)

) AS dim1_results

/* =============================================================================
   DIMENSION 2. QUERY RATES
   (All-Hours vs Peak-Hours, Dashboard vs Non-Dashboard)
   Source: A_1_query3_looker_queries_rate.sql

   PURPOSE
   Summarizes how many Looker queries are started per minute over the date
   range. Results are split into:
     - All-Hours vs Peak-Hours
     - Dashboard-only vs Non-dashboard queries
   For each combination, baseline (average), P95, and maximum query rates
   are reported.
   ============================================================================= */

UNION ALL

/* --- DIMENSION 2: COLUMN HEADINGS --- */
SELECT
  'D2_COLUMN_HEADINGS'          AS result_section,
  'time_scope | query_category' AS key_value,
  'baseline_queries_per_min'    AS metric_value,
  'max_queries_per_min'         AS col_4,
  'p95_queries_per_min'         AS col_5

UNION ALL

/* --- DIMENSION 2: QUERY RATE DATA --- */
SELECT
  'D2_QUERY_RATE'                                         AS result_section,
  CONCAT(bm.time_scope, ' | ', bm.query_category)        AS key_value,
  ROUND(bm.baseline_queries_per_minute, 2)                AS metric_value,
  bm.max_queries_per_minute                               AS col_4,
  (
    SELECT qpm2.queries_started_in_minute
    FROM (
      SELECT
        qpm_inner.queries_started_in_minute,
        @d2rn := @d2rn + 1 AS rownum
      FROM (
        SELECT qpm_sub.queries_started_in_minute
        FROM d2_queries_per_minute qpm_sub
        WHERE qpm_sub.time_scope     = bm.time_scope
          AND qpm_sub.query_category = bm.query_category
        ORDER BY qpm_sub.queries_started_in_minute
      ) qpm_inner
      CROSS JOIN (SELECT @d2rn := 0) r
    ) qpm2
    WHERE qpm2.rownum >= CEIL(0.95 * bm.total_minutes)
    ORDER BY qpm2.rownum
    LIMIT 1
  )                                                       AS col_5
FROM d2_base_metrics bm;


/* =============================================================================
   DIMENSION 3. OVERLAPPING / CONCURRENT QUERIES
   Source: A_1_query4_looker_queries_overlapping.sql

   PURPOSE
   Measures how many queries are executing simultaneously during peak hours.
   Establishes the true concurrency envelope that the Power BI gateway and
   Redshift WLM must absorb.
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query4_looker_queries_overlapping.sql)


/* =============================================================================
   DIMENSION 4. QUERY FAN-OUT
   Source: A_1_query5_fan-out.sql

   PURPOSE
   Measures how many SQL queries a single dashboard load generates against
   Redshift (i.e. the fan-out ratio per dashboard session). Used to estimate
   the multiplier between Power BI report refreshes and downstream Redshift
   query volume.
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query5_fan-out.sql)


/* =============================================================================
   DIMENSION 5. CACHING
   Source: A_1_query6_caching.sql

   PURPOSE
   Quantifies how much of the current load is absorbed by Looker's query
   cache. A high cache-hit rate means the raw Redshift load is lower than
   the total query count suggests. This factor must be accounted for when
   sizing the Power BI gateway (which has no equivalent cache layer by default).
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query6_caching.sql)


/* =============================================================================
   DIMENSION 6. QUERY SHAPE
   Source: A_1_query7_query_shape.sql

   PURPOSE
   Characterises the SQL queries that reach Redshift: runtime distribution,
   result-set size, and query patterns. Drives selection of representative
   DAX query templates in Phase C of the load-test plan.
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query7_query_shape.sql)


/* =============================================================================
   DIMENSION 7. REDSHIFT WLM QUEUE TIME
   Source: A_1_query8_redshift_wlm_queue_time.sql

   PURPOSE
   Measures time queries spend waiting in Redshift WLM queues during peak
   hours. High queue time indicates Redshift is already a bottleneck and must
   be factored into baseline latency expectations for the Power BI workload.
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query8_redshift_wlm_queue_time.sql)


/* =============================================================================
   DIMENSION 8. REDSHIFT CPU SATURATION
   Source: A_1_query9_redshift_CPU_saturation.sql

   PURPOSE
   Measures Redshift CPU utilisation during peak dashboard hours. Establishes
   the headroom (or lack thereof) available to absorb the Power BI workload
   and informs whether a Redshift scaling change is needed alongside the
   gateway sizing exercise.
   ============================================================================= */

-- TODO: SQL placeholder (A_1_query9_redshift_CPU_saturation.sql)


/* =============================================================================
   DIAGNOSTIC — DAYS WITH DASHBOARD QUERIES BUT NO IDENTIFIED PEAK HOUR

   PURPOSE
   Investigates the discrepancy between 'Days with dashboard queries' and
   'Total daily peak hours analysed' in REPORT_METADATA.

   Copy and paste this standalone query into SQL Runner separately.
   Edit the date range below to match the main query's date_range CTE.

   COLUMNS
   missing_date              : The calendar date (Pacific) that was dropped
   hours_tied_for_max        : Number of hours that shared the same max runtime
                               on that day. If > 1, hypothesis (a) — a tie in
                               hourly runtime prevented the CTE from resolving
                               a single peak hour cleanly.
   max_hourly_runtime_secs   : Total dashboard runtime in the busiest hour.
                               If 0 or very small, hypothesis (c) — zero-runtime
                               sessions counted by D0 but invisible to peak logic.
   total_queries_that_day    : Confirms dashboard queries genuinely existed.
   distinct_hours_with_data  : How many hours had at least one dashboard query.
   ============================================================================= */

/*
WITH date_range AS (
  SELECT
    '2025-11-01' AS analysis_range_first_day,   -- edit to match main query
    '2026-04-30' AS analysis_range_last_day      -- edit to match main query
),

-- Hourly dashboard runtime per day — same aggregation as the main query
hourly_runtimes AS (
  SELECT
    DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
      AS completed_date_pacific,
    HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
      AS completed_hour_pacific,
    SUM(h.runtime) AS hourly_runtime,
    COUNT(*)       AS query_count
  FROM history h
  JOIN date_range dr ON 1=1
  WHERE CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
    AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
    AND h.dashboard_id IS NOT NULL
  GROUP BY 1, 2
),

-- Max hourly runtime per day
daily_max AS (
  SELECT
    completed_date_pacific,
    MAX(hourly_runtime) AS max_hourly_runtime
  FROM hourly_runtimes
  GROUP BY completed_date_pacific
),

-- Reproduces the daily_peak_hours CTE logic from the main query exactly
daily_peak_hours AS (
  SELECT
    hr.completed_date_pacific,
    MIN(hr.completed_hour_pacific) AS peak_hour_pacific
  FROM hourly_runtimes hr
  JOIN daily_max dm
    ON hr.completed_date_pacific = dm.completed_date_pacific
   AND hr.hourly_runtime         = dm.max_hourly_runtime
  GROUP BY hr.completed_date_pacific
)

-- Dates present in hourly data but absent from daily_peak_hours
SELECT
  hr.completed_date_pacific                                         AS missing_date,
  SUM(CASE WHEN hr.hourly_runtime = dm.max_hourly_runtime
           THEN 1 ELSE 0 END)                                       AS hours_tied_for_max,
  dm.max_hourly_runtime                                             AS max_hourly_runtime_secs,
  SUM(hr.query_count)                                               AS total_queries_that_day,
  COUNT(DISTINCT hr.completed_hour_pacific)                         AS distinct_hours_with_data
FROM hourly_runtimes hr
JOIN daily_max dm
  ON hr.completed_date_pacific = dm.completed_date_pacific
LEFT JOIN daily_peak_hours dph
  ON hr.completed_date_pacific = dph.completed_date_pacific
WHERE dph.completed_date_pacific IS NULL   -- missing dates only
GROUP BY hr.completed_date_pacific, dm.max_hourly_runtime
ORDER BY hr.completed_date_pacific;
*/
