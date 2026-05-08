/* =============================================================================
   A.1.1b — PEAK HOUR PATTERNS & DASHBOARD RECURRENCE (READ-ONLY)

   PURPOSE
   Summarizes daily peak *interactive dashboard* behavior across an extended
   period and presents the results as a self-describing report.

   Scope:
   - Dashboard-generated queries only (history.dashboard_id IS NOT NULL)
   - One peak hour per day (hour with max dashboard runtime)
   ============================================================================= */

WITH date_range AS (
  SELECT
    '2026-01-05' AS analysis_range_first_day,
    '2026-04-26' AS analysis_range_last_day
),

/* ---------------------------------------------------------------------------
   IDENTIFY DAILY PEAK DASHBOARD HOUR (PACIFIC TIME)
   --------------------------------------------------------------------------- */
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
      GROUP BY 1,2
    ) x
    GROUP BY completed_date_pacific
  ) mx
    ON hourly.completed_date_pacific = mx.completed_date_pacific
   AND hourly.hourly_dashboard_runtime = mx.max_runtime
  GROUP BY completed_date_pacific
),

/* ---------------------------------------------------------------------------
   DAILY PEAK HOUR RUNTIME MAGNITUDE
   --------------------------------------------------------------------------- */
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

/* ---------------------------------------------------------------------------
   DASHBOARD PARTICIPATION IN DAILY PEAK HOURS
   --------------------------------------------------------------------------- */
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

/* ---------------------------------------------------------------------------
   RANK PEAK RUNTIMES (MYSQL 5.7 SAFE — NO WINDOW FUNCTIONS)
   --------------------------------------------------------------------------- */
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
)

/* ---------------------------------------------------------------------------
   FINAL SINGLE RESULT SET (REPORT FORMAT)
   --------------------------------------------------------------------------- */

/* --- REPORT METADATA --- */
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
  'Total daily peak hours analysed',
  (SELECT COUNT(*) FROM daily_peak_hours)

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


/* --- SECTION B METADATA (EXPLAINER) --- */
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
       >= 0.25 * (SELECT COUNT(*) FROM daily_peak_hours);