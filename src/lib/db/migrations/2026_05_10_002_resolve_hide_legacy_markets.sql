-- Legacy cleanup for pre-cutover markets in existing forks/environments.
-- NOTE: this schema does not persist the CTF exchange address per market.
-- We therefore cut by market creation timestamp (pre-cutover) instead.
--
-- Cutover chosen from production deploy evidence:
--   - last legacy-market registration observed in poly-syncer:
--     2026-05-01T08:06:09.707Z (legacy NegRisk CTF exchange)
--   - no market registrations found on the new exchanges before that timestamp.
--   - this migration uses the same timestamp as the legacy/new boundary.
--
--   markets created before this timestamp are treated as legacy
--   markets created at/after this timestamp are treated as post-cutover

WITH legacy_markets AS (
  SELECT m.condition_id, m.event_id
  FROM markets m
  WHERE m.created_at < '2026-05-01T08:06:09.707Z'::timestamptz
),
updated_conditions AS (
  UPDATE conditions c
  SET
    resolved = TRUE,
    resolution_status = COALESCE(c.resolution_status, 'resolved'),
    resolution_last_update = COALESCE(c.resolution_last_update, NOW()),
    updated_at = NOW()
  WHERE c.id IN (SELECT lm.condition_id FROM legacy_markets lm)
  RETURNING c.id
),
updated_markets AS (
  UPDATE markets m
  SET
    is_resolved = TRUE,
    is_active = FALSE,
    updated_at = NOW()
  WHERE m.condition_id IN (SELECT lm.condition_id FROM legacy_markets lm)
  RETURNING m.event_id, m.condition_id
),
event_rollup AS (
  SELECT
    m.event_id,
    COUNT(*) FILTER (WHERE m.is_active = TRUE) AS active_markets_count,
    COUNT(*) AS total_markets_count,
    COUNT(*) FILTER (WHERE m.is_resolved = FALSE) AS unresolved_count
  FROM markets m
  WHERE m.event_id IN (SELECT DISTINCT lm.event_id FROM legacy_markets lm)
  GROUP BY m.event_id
)
UPDATE events e
SET
  active_markets_count = er.active_markets_count,
  total_markets_count = er.total_markets_count,
  status = CASE
    WHEN er.unresolved_count = 0 THEN 'resolved'
    ELSE e.status
  END,
  resolved_at = CASE
    WHEN er.unresolved_count = 0 THEN COALESCE(e.resolved_at, NOW())
    ELSE e.resolved_at
  END,
  is_hidden = CASE
    WHEN er.unresolved_count = 0 THEN TRUE
    ELSE e.is_hidden
  END,
  updated_at = NOW()
FROM event_rollup er
WHERE e.id = er.event_id;
