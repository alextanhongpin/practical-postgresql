# Rollups (Summaries Without Storing Everything)

## Problem / Context

Your dashboard shows “top users this week,” “daily active users,” and “page views per day.” Reading raw events every time is slow and expensive. You need summaries that are fast to query, while staying reasonably fresh.

## Core Concept

- Rollups are aggregate summaries (SUM/COUNT/etc.) grouped by keys (user_id, day).
- Two modes: compute on demand (always fresh) or precompute/store (fast reads, some staleness).
- Incremental rollups process only new data since a watermark to keep work small.

A rollup is “sum / count / stats grouped by something.” Do it on demand (fresh but maybe slow) or pre-store (fast but stale risk). Choose per use case.

## Implementation (step by step SQL)

## 1. Basic leaderboard

```sql
CREATE TABLE game_score (
  user_id INT,
  score   INT,
  played_at timestamptz
);
-- Sample data
INSERT INTO game_score (user_id, score, played_at) VALUES
  (1, 10, now() - interval '5 days'),
  (1, 20, now() - interval '4 days'),
  (1, 15, now() - interval '3 days'),
  (2,  5, now() - interval '5 days'),
  (2, 30, now() - interval '3 days'),
  (3, 50, now() - interval '5 days'),
  (3, 10, now() - interval '2 days'),
  (4,  8, now() - interval '3 days');
-- Total per user
SELECT user_id, SUM(score) AS total_score
FROM game_score
GROUP BY user_id
ORDER BY total_score DESC
LIMIT 10;
-- Daily leaderboard
SELECT user_id, date(played_at) AS day, SUM(score) AS daily_score
FROM game_score
GROUP BY user_id, day
ORDER BY day DESC, daily_score DESC;
```

## 2. Page view counts

```sql
CREATE TABLE page_view (
  page_id INT,
  viewed_at timestamptz
);
-- Sample data
INSERT INTO page_view (page_id, viewed_at) VALUES
  (101, now() - interval '5 days'),
  (101, now() - interval '4 days'),
  (102, now() - interval '3 days'),
  (102, now() - interval '3 days'),
  (103, now() - interval '2 days'),
  (103, now() - interval '1 days'),
  (104, now() - interval '1 days');
SELECT page_id, COUNT(*) AS total_views
FROM page_view
GROUP BY page_id
ORDER BY total_views DESC;
SELECT page_id, date(viewed_at) AS day, COUNT(*) AS daily_views
FROM page_view
GROUP BY page_id, day
ORDER BY day DESC, daily_views DESC;
```

## 3. When it gets slow

Full scans hurt once rows explode. Options:

- Covering index on (grouping_column [, date])
- Pre-aggregate periodically into a smaller table
- Materialized view with refresh
- Incremental “delta” merges

## 4. Incremental pattern (add only new rows)

Store last processed timestamp + accumulated totals.

```sql
CREATE TABLE leaderboard_rollup (
  user_id INT PRIMARY KEY,
  total_score BIGINT NOT NULL DEFAULT 0,
  last_updated timestamptz
);
WITH last AS (
  SELECT coalesce(max(last_updated), to_timestamp(0)) AS last_ts FROM leaderboard_rollup
)
INSERT INTO leaderboard_rollup (user_id,total_score,last_updated)
SELECT user_id, SUM(score), now()
FROM game_score, last
WHERE played_at > last.last_ts
GROUP BY user_id
ON CONFLICT (user_id)
DO UPDATE SET total_score = leaderboard_rollup.total_score + EXCLUDED.total_score,
              last_updated = EXCLUDED.last_updated;
```

Same idea for page views.

```sql
CREATE TABLE page_view_rollup (
  page_id INT PRIMARY KEY,
  total_views BIGINT NOT NULL DEFAULT 0,
  last_updated timestamptz
);
WITH last AS (
  SELECT coalesce(max(last_updated), to_timestamp(0)) AS last_ts FROM page_view_rollup
)
INSERT INTO page_view_rollup (page_id,total_views,last_updated)
SELECT page_id, COUNT(*), now()
FROM page_view, last
WHERE viewed_at > last.last_ts
GROUP BY page_id
ON CONFLICT (page_id)
DO UPDATE SET total_views = page_view_rollup.total_views + EXCLUDED.total_views,
              last_updated = EXCLUDED.last_updated;
```

## 5. Materialized view alternative

```sql
CREATE MATERIALIZED VIEW leaderboard_mv AS
SELECT user_id, SUM(score) AS total_score
FROM game_score GROUP BY user_id;

CREATE UNIQUE INDEX ON leaderboard_mv (user_id);

-- Later
REFRESH MATERIALIZED VIEW CONCURRENTLY leaderboard_mv; -- needs unique index
```

Pros: fast reads. Cons: refresh lag + overhead.

## 6. Hybrid strategy

- Real-time last X minutes from base table
- Historical older data from rollup table/materialized view
- UNION ALL them for a “live” dashboard.

## 7. Correctness pitfalls

- Late arriving rows (timestamps out of order) → design a grace window (process last 5 minutes again) or store watermark and allow minor duplication then de-dup.
- Clock skew (multiple app servers) → prefer server-generated timestamptz default.
- Double counting: ensure incremental WHERE strictly greater than last watermark, or record high-water mark separately.

## 8. Performance tips

- Avoid COUNT(\*) over giant unfiltered table for every dashboard refresh; cache result for a short TTL.
- Batch updates (process 10k rows per run) to keep VACUUM happy.
- Use BIGINT for accumulating counters.

## 9. Choosing cheat sheet

| Need                      | Pick                                   |
| ------------------------- | -------------------------------------- |
| Fresh every view          | On-demand GROUP BY                     |
| Fast repeated heavy query | Materialized view or rollup table      |
| Large stream append       | Incremental rollup + final MV snapshot |
| Mixed real-time + history | Hybrid (recent live + old pre-agg)     |

## 10. Recap

Rollups trade compute (do it now) for storage (do it once, serve many). Start with plain GROUP BY. Add incremental table or MV only when latency or cost becomes painful.

## Variations and Trade‑Offs

- On-demand GROUP BY is simple and fresh but can be slow at scale.
- Materialized views make reads fast, but you need to schedule REFRESH and handle staleness.
- Incremental tables are flexible and can be near real‑time, but need careful watermarking and de‑duplication.
- Hybrid approach gives “live-ish” dashboards: small real-time window from base tables plus historical rollups.

## Pitfalls

- Double counting when merging increments; always use a strict watermark and idempotent upserts.
- Late events arriving out of order; re-scan a small grace window.
- Forgetting a unique index for REFRESH MATERIALIZED VIEW CONCURRENTLY.
- Summaries drifting from source of truth; schedule audits or recompute periodically.

## Recap (Short Summary)

Start with a plain GROUP BY. When queries get slow, add either a materialized view or an incremental rollup table. Handle late data with a grace window and protect against double counting.

## Optional Exercises

- Add a monthly rollup table and write a job that processes only new events.
- Build a materialized view for page views and schedule a concurrent refresh.
- Create a hybrid query that unions “last 15 minutes live” with “older than 15 minutes from rollup.”

## Summary (Cheat Sheet)

- **Purpose**: Summarize large detail sets either on-demand or precomputed.
- **On-Demand**: Use GROUP BY; always fresh but slower at scale.
- **Incremental**: Process only new rows after a watermark; handle late arrivals.
- **Materialized View**: Fast snapshot with periodic REFRESH; stale between refreshes.
- **Hybrid**: Combine recent live data with historical rollups; merging adds complexity.
- **Indexing**: Index group-by columns and time for incremental scans; avoid oversized indexes.
- **Pitfalls**: Double counting, missing late arrivals, and materialized view lock contention.
- **Decision Starter**: Start with plain queries; add a materialized view; add incremental processing if latency is unacceptable.

## References

- Materialized views: https://www.postgresql.org/docs/current/rules-materializedviews.html
- Incremental refresh (approaches): https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html
