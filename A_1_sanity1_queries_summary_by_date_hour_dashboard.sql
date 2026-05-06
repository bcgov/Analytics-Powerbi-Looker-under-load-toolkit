
/* =============================================================================
   SANITY CHECK — SUMMARY OF QUERIES BY DASHBOARD / DATE / HOUR (READ-ONLY)

   PURPOSE
   Returns a summary statement of all queries executed for a single dashboard 
   during a specific Pacific Time date and hour. Intended for validation and debugging.

   Connection: looker_mysql_direct
   Schema: looker
   Table: history
   ============================================================================= */


/* READ-ONLY QUERY
   This SQL is strictly read-only. It only SELECTs and aggregates existing data
   and does NOT insert, update, delete, or modify any database objects.
*/

WITH params AS (
  SELECT
    '2026-04-22' AS target_date_pacific,  -- YYYY-MM-DD (Pacific)
    10           AS target_hour_pacific,  -- 0–23 (Pacific)
    1234         AS target_dashboard_id   -- dashboard_id
)

SELECT
  CONCAT(
    'On ',
    p.target_date_pacific,
    ' during ',
    LPAD(p.target_hour_pacific, 2, '0'),
    ':00 Pacific, dashboard ',
    p.target_dashboard_id,
    ' had ',
    COUNT(*),
    ' queries that ran for a total of ',
    ROUND(SUM(h.runtime), 1),
    ' seconds, used by ',
    COUNT(DISTINCT h.user_id),
    ' users in ',
    COUNT(DISTINCT h.dashboard_session),
    ' sessions.'
  ) AS summary_text

FROM history h
CROSS JOIN params p
WHERE h.dashboard_id = p.target_dashboard_id
  AND DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        = p.target_date_pacific
  AND HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        = p.target_hour_pacific;