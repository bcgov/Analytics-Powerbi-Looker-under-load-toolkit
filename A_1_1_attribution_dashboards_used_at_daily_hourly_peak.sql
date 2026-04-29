/* =============================================================================
   QUERY ATTRIBUTION (READ-ONLY)

   PURPOSE
   This query identifies the busiest dashboard hour (Pacific Time) for each day
   in a given date range, then shows which dashboards were responsible for that
   peak load and how much each contributed.
   ============================================================================= */

/* READ-ONLY QUERY
   This SQL is strictly read-only. It only SELECTs and aggregates existing data
   and does NOT insert, update, delete, or modify any database objects. */

/* ---------------------------------------------------------------------------
   INPUT
   Run this query in SQL Runner
   Connection: looker_mysql_direct
   Schema: looker
   Table: history

   The history table records every query executed by Looker, including timing,
   runtime, dashboard attribution, user, session, and cache information.
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   ANALYSIS DATE RANGE
   Edit these two values to change the Pacific-time date window used throughout
   the analysis. The start date is inclusive and the end date is exclusive.
   --------------------------------------------------------------------------- */
WITH date_range AS (
  SELECT
    '2026-04-21' AS analysis_range_first_day,
    '2026-04-24' AS analysis_range_last_day
),

/* ---------------------------------------------------------------------------
   IDENTIFY PEAK DASHBOARD HOUR PER DAY
   Determines, for each day, the Pacific-time hour when dashboards consumed
   the most total query runtime.
   --------------------------------------------------------------------------- */
peak_hours AS (
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
    FROM history h, date_range dr
    WHERE CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
      AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
      AND h.dashboard_id IS NOT NULL
    GROUP BY
      completed_date_pacific,
      completed_hour_pacific
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
      FROM history h2, date_range dr2
      WHERE CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            >= dr2.analysis_range_first_day
        AND CONVERT_TZ(h2.completed_at,'UTC','America/Vancouver')
            <  dr2.analysis_range_last_day
        AND h2.dashboard_id IS NOT NULL
      GROUP BY
        completed_date_pacific,
        completed_hour_pacific
    ) x
    GROUP BY x.completed_date_pacific
  ) mx
    ON hourly.completed_date_pacific = mx.completed_date_pacific
   AND hourly.hourly_dashboard_runtime = mx.max_runtime
  GROUP BY hourly.completed_date_pacific
),

/* ---------------------------------------------------------------------------
   DASHBOARD ATTRIBUTION DURING PEAK HOUR
   Pulls all dashboard-generated queries executed during each day’s peak
   dashboard hour so load can be attributed per dashboard.
   --------------------------------------------------------------------------- */
dashboard_peak_queries AS (
  SELECT
    ph.completed_date_pacific,
    ph.completed_hour_pacific,
    h.dashboard_id,
    h.dashboard_session,
    h.user_id,
    h.cache,
    h.runtime
  FROM history h
  JOIN peak_hours ph
    ON DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.completed_date_pacific
   AND HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
         = ph.completed_hour_pacific
  CROSS JOIN date_range dr
  WHERE h.dashboard_id IS NOT NULL
    AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          >= dr.analysis_range_first_day
    AND CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
          <  dr.analysis_range_last_day
),

/* ---------------------------------------------------------------------------
   PEAK-HOUR TOTALS
   Computes total runtime and total query count for each peak hour. These
   values are used to calculate per-dashboard percentages.
   --------------------------------------------------------------------------- */
peak_hour_totals AS (
  SELECT
    dpq.completed_date_pacific,
    dpq.completed_hour_pacific,
    SUM(dpq.runtime) AS total_runtime_peak_hour,
    COUNT(*) AS total_queries_peak_hour
  FROM dashboard_peak_queries dpq
  GROUP BY
    dpq.completed_date_pacific,
    dpq.completed_hour_pacific
)

/* ---------------------------------------------------------------------------
   FINAL OUTPUT
   One row per dashboard, per day, during the busiest dashboard hour.
   --------------------------------------------------------------------------- */
SELECT
  dpq.completed_date_pacific,
  dpq.completed_hour_pacific
    AS hour_of_day_pacific_for_max_daily_runtime_seconds,
  dpq.dashboard_id,

  /* Workload */
  ROUND(SUM(dpq.runtime), 0) AS dashboard_runtime_seconds,
  COUNT(*) AS dashboard_query_count,

  /* Usage proxies */
  COUNT(DISTINCT dpq.dashboard_session) AS dashboard_sessions_count,
  COUNT(DISTINCT dpq.user_id) AS distinct_users_count,

  /* Cache behavior */
  SUM(CASE WHEN dpq.cache = 'hit' THEN 1 ELSE 0 END) AS cached_query_count,

  /* Share of peak-hour load */
  ROUND(
    100.0 * SUM(dpq.runtime) / pht.total_runtime_peak_hour,
    1
  ) AS pct_of_peak_hour_runtime,

  ROUND(
    100.0 * COUNT(*) / pht.total_queries_peak_hour,
    1
  ) AS pct_of_peak_hour_query_count

FROM dashboard_peak_queries dpq
JOIN peak_hour_totals pht
  ON dpq.completed_date_pacific = pht.completed_date_pacific
 AND dpq.completed_hour_pacific = pht.completed_hour_pacific

GROUP BY
  dpq.completed_date_pacific,
  dpq.completed_hour_pacific,
  dpq.dashboard_id,
  pht.total_runtime_peak_hour,
  pht.total_queries_peak_hour

ORDER BY
  dpq.completed_date_pacific,
  pct_of_peak_hour_runtime DESC;
