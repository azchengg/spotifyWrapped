-- =====================================================================
-- Spotify-style analysis queries (SQLite)
-- Run all:  sqlite3 -header -column spotify.db < queries.sql
-- Most per-user queries use user_id = 1; change it to explore others.
-- =====================================================================


-- =====================================================================
-- PART 1: PLATFORM BASICS
-- =====================================================================

-- Q1. Catalog size per artist (joins + GROUP BY)
SELECT a.name, a.genre,
       COUNT(DISTINCT al.album_id) AS albums,
       COUNT(t.track_id)           AS tracks
FROM artists a
JOIN albums al ON al.artist_id = a.artist_id
JOIN tracks t  ON t.album_id   = al.album_id
GROUP BY a.artist_id
ORDER BY tracks DESC
LIMIT 10;

-- Q2. Top 10 most streamed tracks platform-wide (a "stream" = not skipped)
SELECT track, artist, COUNT(*) AS streams
FROM v_plays
WHERE skipped = 0
GROUP BY track_id
ORDER BY streams DESC
LIMIT 10;

-- Q3. Skip rate by genre
SELECT genre,
       COUNT(*)                          AS plays,
       ROUND(100.0 * AVG(skipped), 1)    AS skip_rate_pct
FROM v_plays
GROUP BY genre
ORDER BY skip_rate_pct DESC;

-- Q4. When do people listen? Plays by hour of day
SELECT hour, COUNT(*) AS plays,
       SUBSTR('████████████████████████████████████████', 1,
              CAST(40.0 * COUNT(*) / MAX(COUNT(*)) OVER () AS INTEGER)) AS bar
FROM v_plays
GROUP BY hour
ORDER BY hour;

-- Q5. Do premium users listen more? Average minutes per user by plan
SELECT u.plan,
       COUNT(DISTINCT u.user_id)                         AS users,
       ROUND(SUM(p.minutes) / COUNT(DISTINCT u.user_id)) AS avg_minutes_per_user
FROM users u
JOIN v_plays p ON p.user_id = u.user_id
GROUP BY u.plan;


-- =====================================================================
-- PART 2: "WRAPPED" FOR ONE USER, ONE YEAR (user 1, 2025)
-- =====================================================================

-- Q6. Total minutes listened
SELECT u.username, ROUND(SUM(p.minutes)) AS minutes_listened,
       COUNT(DISTINCT p.track_id)        AS different_tracks,
       COUNT(DISTINCT p.artist_id)       AS different_artists
FROM v_plays p
JOIN users u ON u.user_id = p.user_id
WHERE p.user_id = 1 AND p.year = 2025;

-- Q7. Top 5 artists
SELECT artist, genre, ROUND(SUM(minutes)) AS minutes
FROM v_plays
WHERE user_id = 1 AND year = 2025
GROUP BY artist_id
ORDER BY minutes DESC
LIMIT 5;

-- Q8. Top 5 songs
SELECT track, artist, COUNT(*) AS plays
FROM v_plays
WHERE user_id = 1 AND year = 2025 AND skipped = 0
GROUP BY track_id
ORDER BY plays DESC
LIMIT 5;

-- Q9. Top genres with share of listening (window function over the total)
SELECT genre,
       ROUND(SUM(minutes))                                      AS minutes,
       ROUND(100.0 * SUM(minutes) / SUM(SUM(minutes)) OVER (), 1) AS pct
FROM v_plays
WHERE user_id = 1 AND year = 2025
GROUP BY genre
ORDER BY minutes DESC;

-- Q10. Longest daily listening streak ("gaps and islands")
-- Consecutive dates minus their row number give the same anchor date.
WITH days AS (
    SELECT DISTINCT play_date FROM v_plays WHERE user_id = 1 AND year = 2025
),
islands AS (
    SELECT play_date,
           DATE(play_date, '-' || ROW_NUMBER() OVER (ORDER BY play_date) || ' days') AS grp
    FROM days
)
SELECT MIN(play_date) AS streak_start, MAX(play_date) AS streak_end,
       COUNT(*)       AS days_in_a_row
FROM islands
GROUP BY grp
ORDER BY days_in_a_row DESC
LIMIT 1;

-- Q11. "You're in the top X% of listeners" for each of your top artists
WITH artist_minutes AS (
    SELECT user_id, artist_id, artist, SUM(minutes) AS minutes
    FROM v_plays
    WHERE year = 2025
    GROUP BY user_id, artist_id
),
ranked AS (
    SELECT *, PERCENT_RANK() OVER (PARTITION BY artist_id ORDER BY minutes DESC) AS pr
    FROM artist_minutes
)
SELECT artist, ROUND(minutes) AS minutes,
       'top ' || MAX(1, CAST(ROUND(100 * pr) AS INTEGER)) || '%' AS fan_rank
FROM ranked
WHERE user_id = 1
ORDER BY minutes DESC
LIMIT 5;

-- Q12. Artists you listen to a lot but don't follow (anti-join)
SELECT p.artist, ROUND(SUM(p.minutes)) AS minutes
FROM v_plays p
WHERE p.user_id = 1 AND p.year = 2025
  AND NOT EXISTS (SELECT 1 FROM follows f
                  WHERE f.user_id = p.user_id AND f.artist_id = p.artist_id)
GROUP BY p.artist_id
ORDER BY minutes DESC
LIMIT 5;


-- =====================================================================
-- PART 3: HOW TASTE CHANGES OVER TIME AND BY SEASON
-- =====================================================================

-- Q13. Your genre mix by season (pivot with conditional aggregation)
-- Each cell is the % of that season's listening that went to the genre.
WITH s AS (
    SELECT season, genre, SUM(minutes) AS m
    FROM v_plays
    WHERE user_id = 1
    GROUP BY season, genre
),
share AS (
    SELECT season, genre, 100.0 * m / SUM(m) OVER (PARTITION BY season) AS pct
    FROM s
)
SELECT genre,
       ROUND(SUM(CASE WHEN season = 'winter' THEN pct END), 1) AS winter,
       ROUND(SUM(CASE WHEN season = 'spring' THEN pct END), 1) AS spring,
       ROUND(SUM(CASE WHEN season = 'summer' THEN pct END), 1) AS summer,
       ROUND(SUM(CASE WHEN season = 'fall'   THEN pct END), 1) AS fall
FROM share
GROUP BY genre
ORDER BY genre;

-- Q14. Your "seasonal signature": the genre each season over-indexes on.
-- lift = season share / all-year share. 2.0 means twice as much as usual.
WITH season_genre AS (
    SELECT season, genre, SUM(minutes) AS m FROM v_plays WHERE user_id = 1 GROUP BY season, genre
),
season_share AS (
    SELECT season, genre, m / SUM(m) OVER (PARTITION BY season) AS share FROM season_genre
),
baseline AS (
    SELECT genre, SUM(m) / (SELECT SUM(m) FROM season_genre) AS share
    FROM season_genre GROUP BY genre
),
lifted AS (
    SELECT s.season, s.genre, s.share, s.share / b.share AS lift,
           ROW_NUMBER() OVER (PARTITION BY s.season ORDER BY s.share / b.share DESC) AS rn
    FROM season_share s JOIN baseline b ON b.genre = s.genre
)
SELECT season, genre AS signature_genre,
       ROUND(100 * share, 1) AS pct_of_season, ROUND(lift, 2) AS lift
FROM lifted
WHERE rn = 1
ORDER BY CASE season WHEN 'winter' THEN 1 WHEN 'spring' THEN 2 WHEN 'summer' THEN 3 ELSE 4 END;

-- Q15. Monthly taste-shift score.
-- Compares each month's genre mix to the previous month's using
-- total variation distance: 0 = identical mix, 100 = no overlap at all.
WITH monthly AS (
    SELECT month, genre, SUM(minutes) AS m FROM v_plays WHERE user_id = 1 GROUP BY month, genre
),
months AS (SELECT DISTINCT month FROM monthly),
genres AS (SELECT DISTINCT genre FROM artists),
grid AS (  -- every month x every genre, so a genre you dropped counts as 0
    SELECT mo.month, g.genre, COALESCE(m.m, 0) AS m
    FROM months mo CROSS JOIN genres g
    LEFT JOIN monthly m ON m.month = mo.month AND m.genre = g.genre
),
share AS (
    SELECT month, genre, m / SUM(m) OVER (PARTITION BY month) AS p FROM grid
),
diffs AS (
    SELECT month, genre,
           ABS(p - LAG(p) OVER (PARTITION BY genre ORDER BY month)) AS d
    FROM share
)
SELECT month,
       ROUND(50 * SUM(d), 1) AS taste_shift,
       SUBSTR('████████████████████████████████████████', 1, CAST(SUM(d) * 40 AS INTEGER)) AS bar
FROM diffs
WHERE d IS NOT NULL
GROUP BY month
ORDER BY month;

-- Q16. Biggest genre movers this year vs last year (Jan-Oct for both)
WITH y AS (
    SELECT year, genre, SUM(minutes) AS m
    FROM v_plays
    WHERE user_id = 1 AND CAST(strftime('%m', played_at) AS INTEGER) <= 10
    GROUP BY year, genre
),
share AS (
    SELECT year, genre, 100.0 * m / SUM(m) OVER (PARTITION BY year) AS pct FROM y
)
SELECT genre,
       ROUND(SUM(CASE WHEN year = 2025 THEN pct END), 1) AS pct_2025,
       ROUND(SUM(CASE WHEN year = 2026 THEN pct END), 1) AS pct_2026,
       ROUND(COALESCE(SUM(CASE WHEN year = 2026 THEN pct END), 0)
           - COALESCE(SUM(CASE WHEN year = 2025 THEN pct END), 0), 1) AS change_pts
FROM share
GROUP BY genre
ORDER BY change_pts DESC;

-- Q17. Explorer vs. comfort listener, month by month.
-- A play is "discovery" if it's the first time you ever played that track.
WITH flagged AS (
    SELECT month,
           ROW_NUMBER() OVER (PARTITION BY track_id ORDER BY played_at) = 1 AS is_first
    FROM v_plays WHERE user_id = 1
)
SELECT month,
       COUNT(*)                              AS plays,
       SUM(is_first)                         AS new_tracks,
       ROUND(100.0 * SUM(is_first) / COUNT(*), 1) AS discovery_pct
FROM flagged
GROUP BY month
ORDER BY month;

-- Q18. Seasonal artists: artists you mostly play in one season
-- (at least 30 plays, with 40%+ of them in a single season).
WITH by_season AS (
    SELECT artist, season, COUNT(*) AS n,
           SUM(COUNT(*)) OVER (PARTITION BY artist_id) AS total
    FROM v_plays WHERE user_id = 1
    GROUP BY artist_id, season
)
SELECT artist, season AS peak_season, n AS plays_in_season, total AS total_plays,
       ROUND(100.0 * n / total, 1) AS pct_in_season
FROM by_season
WHERE total >= 30 AND 1.0 * n / total >= 0.40
ORDER BY pct_in_season DESC;

-- Q19. Platform-wide: which genre peaks in which season?
-- Each genre's share of listening per season, relative to its yearly average.
WITH sg AS (
    SELECT season, genre, SUM(minutes) AS m FROM v_plays GROUP BY season, genre
),
share AS (
    SELECT season, genre, m / SUM(m) OVER (PARTITION BY season) AS p FROM sg
)
SELECT genre,
       ROUND(100 * MAX(CASE WHEN season = 'winter' THEN p END), 1) AS winter,
       ROUND(100 * MAX(CASE WHEN season = 'spring' THEN p END), 1) AS spring,
       ROUND(100 * MAX(CASE WHEN season = 'summer' THEN p END), 1) AS summer,
       ROUND(100 * MAX(CASE WHEN season = 'fall'   THEN p END), 1) AS fall,
       ROUND(100 * (MAX(p) - MIN(p)), 1)                           AS seasonal_swing_pts
FROM share
GROUP BY genre
ORDER BY seasonal_swing_pts DESC;

-- Q20. Which users changed taste the most between 2025 and 2026?
-- Total variation distance between each user's yearly genre mix.
WITH y AS (
    SELECT user_id, year, genre, SUM(minutes) AS m FROM v_plays GROUP BY user_id, year, genre
),
share AS (
    SELECT user_id, year, genre, m / SUM(m) OVER (PARTITION BY user_id, year) AS p FROM y
),
paired AS (
    SELECT g.user_id, g.genre,
           COALESCE((SELECT p FROM share s WHERE s.user_id = g.user_id AND s.genre = g.genre AND s.year = 2025), 0) AS p25,
           COALESCE((SELECT p FROM share s WHERE s.user_id = g.user_id AND s.genre = g.genre AND s.year = 2026), 0) AS p26
    FROM (SELECT DISTINCT u.user_id, a.genre FROM users u CROSS JOIN artists a) g
)
SELECT u.username,
       ROUND(50 * SUM(ABS(p26 - p25)), 1) AS taste_change_score,
       (SELECT genre FROM paired p2 WHERE p2.user_id = p.user_id ORDER BY p25 DESC LIMIT 1) AS top_2025,
       (SELECT genre FROM paired p2 WHERE p2.user_id = p.user_id ORDER BY p26 DESC LIMIT 1) AS top_2026
FROM paired p JOIN users u ON u.user_id = p.user_id
GROUP BY p.user_id
HAVING SUM(p26) > 0 AND SUM(p25) > 0
ORDER BY taste_change_score DESC
LIMIT 10;
