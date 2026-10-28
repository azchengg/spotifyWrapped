-- Spotify-style music streaming database (SQLite)
PRAGMA foreign_keys = ON;

DROP VIEW IF EXISTS v_plays;
DROP TABLE IF EXISTS plays;
DROP TABLE IF EXISTS playlist_tracks;
DROP TABLE IF EXISTS playlists;
DROP TABLE IF EXISTS follows;
DROP TABLE IF EXISTS track_artists;
DROP TABLE IF EXISTS tracks;
DROP TABLE IF EXISTS albums;
DROP TABLE IF EXISTS artists;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id      INTEGER PRIMARY KEY,
    username     TEXT    NOT NULL UNIQUE,
    country      TEXT    NOT NULL,
    plan         TEXT    NOT NULL CHECK (plan IN ('free', 'premium', 'student')),
    joined_at    DATE    NOT NULL
);

CREATE TABLE artists (
    artist_id    INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL,
    genre        TEXT    NOT NULL,
    country      TEXT
);

CREATE TABLE albums (
    album_id     INTEGER PRIMARY KEY,
    artist_id    INTEGER NOT NULL REFERENCES artists(artist_id),
    title        TEXT    NOT NULL,
    release_date DATE    NOT NULL
);

CREATE TABLE tracks (
    track_id     INTEGER PRIMARY KEY,
    album_id     INTEGER NOT NULL REFERENCES albums(album_id),
    title        TEXT    NOT NULL,
    duration_ms  INTEGER NOT NULL CHECK (duration_ms > 0),
    explicit     INTEGER NOT NULL DEFAULT 0 CHECK (explicit IN (0, 1))
);

-- Many-to-many: a track can have featured artists
CREATE TABLE track_artists (
    track_id     INTEGER NOT NULL REFERENCES tracks(track_id),
    artist_id    INTEGER NOT NULL REFERENCES artists(artist_id),
    role         TEXT    NOT NULL CHECK (role IN ('primary', 'featured')),
    PRIMARY KEY (track_id, artist_id)
);

CREATE TABLE follows (
    user_id      INTEGER NOT NULL REFERENCES users(user_id),
    artist_id    INTEGER NOT NULL REFERENCES artists(artist_id),
    followed_at  DATE    NOT NULL,
    PRIMARY KEY (user_id, artist_id)
);

CREATE TABLE playlists (
    playlist_id  INTEGER PRIMARY KEY,
    owner_id     INTEGER NOT NULL REFERENCES users(user_id),
    name         TEXT    NOT NULL,
    is_public    INTEGER NOT NULL DEFAULT 1 CHECK (is_public IN (0, 1)),
    created_at   DATE    NOT NULL
);

CREATE TABLE playlist_tracks (
    playlist_id  INTEGER NOT NULL REFERENCES playlists(playlist_id),
    track_id     INTEGER NOT NULL REFERENCES tracks(track_id),
    position     INTEGER NOT NULL,
    added_at     DATE    NOT NULL,
    PRIMARY KEY (playlist_id, track_id)
);

-- Listening history: one row per play
CREATE TABLE plays (
    play_id      INTEGER PRIMARY KEY,
    user_id      INTEGER  NOT NULL REFERENCES users(user_id),
    track_id     INTEGER  NOT NULL REFERENCES tracks(track_id),
    played_at    DATETIME NOT NULL,
    ms_played    INTEGER  NOT NULL CHECK (ms_played >= 0),
    skipped      INTEGER  NOT NULL DEFAULT 0 CHECK (skipped IN (0, 1)),
    device       TEXT     NOT NULL CHECK (device IN ('phone', 'desktop', 'web', 'speaker'))
);

CREATE INDEX idx_plays_user_time  ON plays(user_id, played_at);
CREATE INDEX idx_plays_track      ON plays(track_id);
CREATE INDEX idx_albums_artist    ON albums(artist_id);
CREATE INDEX idx_track_artists_ar ON track_artists(artist_id);

-- Convenience view: every play with its primary artist, genre, minutes and season.
-- Most analysis queries start from here.
CREATE VIEW v_plays AS
SELECT
    p.play_id,
    p.user_id,
    p.track_id,
    t.title                           AS track,
    a.artist_id,
    a.name                            AS artist,
    a.genre,
    p.played_at,
    DATE(p.played_at)                 AS play_date,
    CAST(strftime('%Y', p.played_at) AS INTEGER) AS year,
    strftime('%Y-%m', p.played_at)    AS month,
    CAST(strftime('%H', p.played_at) AS INTEGER) AS hour,
    CASE
        WHEN CAST(strftime('%m', p.played_at) AS INTEGER) IN (12, 1, 2) THEN 'winter'
        WHEN CAST(strftime('%m', p.played_at) AS INTEGER) IN (3, 4, 5)  THEN 'spring'
        WHEN CAST(strftime('%m', p.played_at) AS INTEGER) IN (6, 7, 8)  THEN 'summer'
        ELSE 'fall'
    END                               AS season,
    p.ms_played / 60000.0             AS minutes,
    p.skipped,
    p.device
FROM plays p
JOIN tracks t         ON t.track_id = p.track_id
JOIN track_artists ta ON ta.track_id = p.track_id AND ta.role = 'primary'
JOIN artists a        ON a.artist_id = ta.artist_id;
