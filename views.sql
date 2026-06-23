-- Views for the draftout dataset.
-- Scope: competitive 1v1 matches, not soft-deleted, excluding 'cancelled'.

-- Base: active competitive matches. Other views build on this.
CREATE OR REPLACE VIEW v_matches AS
SELECT id,
       game_mode,
       outcome,
       completed_tz,
       duration_ms,
       duration_ms / 60000.0               AS duration_min,
       seed,
       picked_first,
       outcome IN ('draw', 'draw_by_vote') AS is_draw
FROM matches
WHERE deleted_at IS NULL
  AND match_type = 'competitive'
  AND outcome <> 'cancelled';

-- Per-participant row with a W/D/L label. Building block for the player views.
CREATE OR REPLACE VIEW v_results AS
SELECT m.id                                                                  AS match_id,
       m.completed_tz,
       p.uuid,
       p.username,
       p.score,
       p.elo_before,
       p.elo_after,
       p.elo_change,
       CASE WHEN m.is_draw THEN 'draw' WHEN p.won THEN 'win' ELSE 'loss' END AS result
FROM v_matches m
         JOIN participants p ON p.match_id = m.id;

-- One row per match, both players pivoted a/b (a = winner when decided).
CREATE OR REPLACE VIEW v_match_summary AS
WITH ranked AS (SELECT m.id                                           AS match_id,
                       m.outcome,
                       m.is_draw,
                       m.completed_tz,
                       round(m.duration_min::numeric, 1)              AS duration_min,
                       p.username,
                       p.score,
                       p.elo_before,
                       p.elo_after,
                       p.elo_change,
                       row_number() OVER (PARTITION BY m.id
                           ORDER BY p.won DESC, p.score DESC, p.uuid) AS rn
                FROM v_matches m
                         JOIN participants p ON p.match_id = m.id)
SELECT a.match_id,
       a.outcome,
       CASE WHEN a.is_draw THEN 'draw' ELSE 'decided' END AS result,
       a.completed_tz,
       a.duration_min,
       a.username                                         AS player_a,
       a.score                                            AS score_a,
       a.elo_before                                       AS elo_before_a,
       a.elo_after                                        AS elo_after_a,
       b.username                                         AS player_b,
       b.score                                            AS score_b,
       b.elo_before                                       AS elo_before_b,
       b.elo_after                                        AS elo_after_b,
       abs(a.elo_change)                                  AS elo_swing
FROM ranked a
         JOIN ranked b ON b.match_id = a.match_id AND b.rn = 2
WHERE a.rn = 1;

-- Career W/D/L and ELO per player (current_name keeps renames as one row).
CREATE OR REPLACE VIEW v_player_stats AS
SELECT r.uuid,
       pl.current_name                                                       AS username,
       count(*)                                                              AS games,
       count(*) FILTER (WHERE r.result = 'win')                              AS wins,
       count(*) FILTER (WHERE r.result = 'draw')                             AS draws,
       count(*) FILTER (WHERE r.result = 'loss')                             AS losses,
       round(100.0 * count(*) FILTER (WHERE r.result = 'win') / count(*), 1) AS win_pct,
       round(avg(r.score), 1)                                                AS avg_score,
       max(r.elo_after)                                                      AS peak_elo
FROM v_results r
         JOIN players pl ON pl.uuid = r.uuid
GROUP BY r.uuid, pl.current_name;

-- Current-ELO ladder (latest rated game), min 20 games.
CREATE OR REPLACE VIEW v_leaderboard AS
WITH cur AS (SELECT DISTINCT ON (uuid) uuid, elo_after AS current_elo
             FROM v_results
             WHERE elo_after IS NOT NULL
             ORDER BY uuid, match_id DESC)
SELECT rank() OVER (ORDER BY cur.current_elo DESC) AS rank,
       s.username,
       cur.current_elo,
       s.peak_elo,
       s.games,
       s.wins,
       s.draws,
       s.losses,
       s.win_pct
FROM cur
         JOIN v_player_stats s ON s.uuid = cur.uuid
WHERE s.games >= 20;

-- Interesting match records. Duration uses real finished games.
CREATE OR REPLACE VIEW v_match_records AS
SELECT *
FROM ((SELECT 'Shortest finished match'    AS record,
              match_id,
              duration_min::text || ' min' AS value,
              player_a,
              score_a,
              player_b,
              score_b
       FROM v_match_summary
       WHERE outcome = 'finished'
         AND duration_min > 0
       ORDER BY duration_min ASC
       LIMIT 1)
      UNION ALL
      (SELECT 'Longest finished match',
              match_id,
              duration_min::text || ' min',
              player_a,
              score_a,
              player_b,
              score_b
       FROM v_match_summary
       WHERE outcome = 'finished'
         AND duration_min > 0
       ORDER BY duration_min DESC
       LIMIT 1)
      UNION ALL
      (SELECT 'Biggest blowout',
              match_id,
              (score_a - score_b)::text || ' pt gap',
              player_a,
              score_a,
              player_b,
              score_b
       FROM v_match_summary
       WHERE result = 'decided'
       ORDER BY score_a - score_b DESC
       LIMIT 1)
      UNION ALL
      (SELECT 'Biggest ELO swing',
              match_id,
              elo_swing::text || ' elo',
              player_a,
              score_a,
              player_b,
              score_b
       FROM v_match_summary
       ORDER BY elo_swing DESC NULLS LAST
       LIMIT 1)
      UNION ALL
      (SELECT 'Highest-rated clash',
              match_id,
              (elo_before_a + elo_before_b)::text || ' combined elo',
              player_a,
              score_a,
              player_b,
              score_b
       FROM v_match_summary
       WHERE elo_before_a IS NOT NULL
         AND elo_before_b IS NOT NULL
       ORDER BY elo_before_a + elo_before_b DESC
       LIMIT 1)) recs;

-- Per-goal draft + completion stats.
CREATE OR REPLACE VIEW v_goal_highlights AS
WITH g AS (SELECT d.goal_id,
                  count(*)                                                                  AS times_offered,
                  count(*) FILTER (WHERE d.picked)                                          AS times_picked,
                  count(*) FILTER (WHERE d.timed_out)                                       AS times_timed_out,
                  count(*) FILTER (WHERE d.picked AND mg.completed)                         AS completed_when_picked,
                  avg(mg.completed_at_ms / 1000.0) FILTER (WHERE d.picked AND mg.completed) AS avg_complete_sec
           FROM draft_picks d
                    JOIN v_matches m ON m.id = d.match_id
                    LEFT JOIN match_goals mg ON mg.match_id = d.match_id AND mg.goal_id = d.goal_id
           GROUP BY d.goal_id)
SELECT goal_id,
       times_offered,
       times_picked,
       times_timed_out,
       round(100.0 * times_picked / times_offered, 1)                    AS pick_pct,
       completed_when_picked,
       round(100.0 * completed_when_picked / NULLIF(times_picked, 0), 1) AS complete_when_picked_pct,
       round(avg_complete_sec::numeric, 1)                               AS avg_complete_sec
FROM g;
