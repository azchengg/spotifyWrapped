# Spotify-Style Listening Analytics (SQL)

A music streaming database with about 65,000 plays from 25 users (Jan 2025 – Oct 2026). It includes "Wrapped"-style yearly summaries and a deeper look at **how music taste changes over time and by season**.

All data is fictional and generated with a fixed random seed, so results are reproducible.

## Quick start

Requires only SQLite (preinstalled on macOS).

```bash
sqlite3 spotify.db < schema.sql
sqlite3 spotify.db < seed.sql
sqlite3 -header -column spotify.db < queries.sql
```

To regenerate the data: `python3 generate_seed.py > seed.sql`

## Schema

| Table | What it holds |
|---|---|
| `users` | username, country, plan (free / premium / student), join date |
| `artists` | name, genre, country |
| `albums` | belongs to an artist, release date |
| `tracks` | belongs to an album, duration, explicit flag |
| `track_artists` | many-to-many: primary and featured artists on a track |
| `follows` | which users follow which artists |
| `playlists` / `playlist_tracks` | user playlists and their ordered tracks |
| `plays` | listening history: one row per play, with ms played, skipped flag, device |

`v_plays` is a view that joins each play to its track, primary artist and genre, and adds handy columns (`year`, `month`, `hour`, `season`, `minutes`). Most queries start from it.

## Queries

### Part 1: Platform basics
| # | Question | SQL concepts |
|---|---|---|
| Q1 | Catalog size per artist | multi-table JOIN, GROUP BY |
| Q2 | Most streamed tracks | filtering, aggregation |
| Q3 | Skip rate by genre | AVG on a 0/1 flag |
| Q4 | Plays by hour of day (with text bar chart) | window over an aggregate |
| Q5 | Listening by subscription plan | COUNT DISTINCT |

### Part 2: Wrapped (one user, one year)
| # | Question | SQL concepts |
|---|---|---|
| Q6 | Total minutes, tracks, artists | aggregates |
| Q7–Q8 | Top artists and songs | ORDER BY + LIMIT |
| Q9 | Genre breakdown as % | `SUM(...) OVER ()` |
| Q10 | Longest daily listening streak | gaps-and-islands with ROW_NUMBER |
| Q11 | "You're in the top X% of listeners" | PERCENT_RANK partitioned by artist |
| Q12 | Artists you play but don't follow | anti-join with NOT EXISTS |

### Part 3: Taste over time and by season
| # | Question | SQL concepts |
|---|---|---|
| Q13 | Genre mix by season | pivot with conditional aggregation |
| Q14 | Seasonal signature genre (what each season over-indexes on) | lift vs baseline, ranking in CTEs |
| Q15 | Monthly taste-shift score | CROSS JOIN grid, LAG, total variation distance |
| Q16 | Biggest genre movers, 2025 vs 2026 | year-over-year pivot |
| Q17 | Discovery rate: new tracks vs repeats | ROW_NUMBER first-occurrence flag |
| Q18 | Artists you mostly play in one season | windowed totals, HAVING-style filter |
| Q19 | Which genres peak in which season, platform-wide | seasonal swing |
| Q20 | Users whose taste changed most year to year | distance metric across users |

### How the taste-shift score works (Q15, Q20)

Each month's listening is turned into a genre mix (e.g. 30% k-pop, 15% jazz, ...). The score compares two mixes with **total variation distance**: half the sum of the absolute differences across genres, scaled to 0–100.

- **0** means the exact same genre mix
- **100** means no genre in common

For example, a jump from 10 to 30 at a change of season means that person's listening changed noticeably then.

## Sample findings (user 1)

- **Seasonal signature:** jazz in winter and fall, indie in spring, hip-hop in summer (Q14). Summer hip-hop is at 2.3× this user's usual share.
- **Year over year:** k-pop fell from 32% to 13% of listening while rock rose from 5% to 24% (Q16).
- **Taste shifts** spike around June, September and January, where the seasons turn (Q15).
- **Discovery** drops from about 70% new tracks in the first month to single digits as they settle into favorites (Q17).

## Ideas to extend

- Add `track_features` (energy, tempo, danceability) and see if people play higher-energy music in summer
- Detect "comfort songs": tracks replayed most after a gap of several weeks
- Recommend artists: users with similar genre mixes, then artists they play that you don't
- Build a small dashboard over `spotify.db` (Python + Streamlit, or Metabase)
