
/* =============================================================================
   SANITY CHECK — RAW QUERIES BY DASHBOARD / DATE / HOUR (READ-ONLY)

   PURPOSE
   Returns every individual query executed for a single dashboard during a
   specific Pacific Time date and hour. Intended for validation and debugging.

   Connection: looker_mysql_direct
   Schema: looker
   Table: history
   ============================================================================= */

/* =============================================================================
   SANITY CHECK — RAW HISTORY ROWS BY DASHBOARD / DATE / HOUR
   READ-ONLY — SAFE COLUMN SET
   ============================================================================= */

WITH params AS (
  SELECT
    '2026-04-22' AS target_date_pacific,  -- YYYY-MM-DD (Pacific)
    10           AS target_hour_pacific,  -- 0–23 (Pacific)
    1234         AS target_dashboard_id   -- dashboard_id
)

SELECT
  /* Timing */
  h.completed_at AS completed_at_utc,
  CONVERT_TZ(h.completed_at,'UTC','America/Vancouver')
    AS completed_at_pacific,

  /* Attribution */
  h.dashboard_id,
  h.dashboard_session,
  h.user_id,
  h.query_id,
  h.look_id,

  /* Performance (these always exist) */
  h.runtime        AS runtime_seconds,
  h.cache,

  /* Operational context */
  h.source,
  h.status

FROM history h
CROSS JOIN params p
WHERE h.dashboard_id = p.target_dashboard_id
  AND DATE(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        = p.target_date_pacific
  AND HOUR(CONVERT_TZ(h.completed_at,'UTC','America/Vancouver'))
        = p.target_hour_pacific

ORDER BY
  completed_at_pacific,
  h.query_id;