# Getting Started: Local Postgres for Testing

Spin up PostgreSQL fast for throwaway experiments or ongoing local work. Pick one of the options below.

## Option A — Docker one‑liner (quick, disposable)

Runs Postgres in the background on port 5432 with a simple password. Good for short sessions.

```
docker run -d --name pg-test \
	-e POSTGRES_USER=postgres \
	-e POSTGRES_PASSWORD=postgres \
	-e POSTGRES_DB=app \
	-p 5432:5432 \
	postgres:16
```

Connect with psql:

```
psql "postgresql://postgres:postgres@localhost:5432/app"
```

Notes

- Stop/remove when done: `docker rm -f pg-test`.
- For persistence across restarts, add a named volume: `-v pgdata:/var/lib/postgresql/data` (and create it once with `docker volume create pgdata`).

## Option B — Docker Compose (persistent dev database)

Create `docker-compose.yml` in your project and bring it up when you need a local DB. This setup adds a healthcheck and a named volume.

```yaml
services:
	db:
		image: postgres:16
		container_name: pg-dev
		ports:
			- "5432:5432"
		environment:
			POSTGRES_USER: postgres
			POSTGRES_PASSWORD: postgres
			POSTGRES_DB: app
		volumes:
			- pgdata:/var/lib/postgresql/data

volumes:
	pgdata: {}
```

Bring it up/down:

```
docker compose up -d
docker compose down
```

Connect:

```
psql "postgresql://postgres:postgres@localhost:5432/app"
```

Optional: export a `DATABASE_URL` for apps/tests.

```
export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/app"
```

## Option C — Zero‑setup online playground

Use a browser-based PostgreSQL to try SQL without installing anything:

- Aiven Playground: https://aiven.io/tools/pg-playground

Great for quick experiments; note that extensions and persistence are limited.

## Quick sanity check (any option)

Run a tiny session to confirm everything works:

```sql
CREATE TABLE IF NOT EXISTS t(id int primary key, v text);
INSERT INTO t VALUES (1,'a') ON CONFLICT DO NOTHING;
SELECT * FROM t ORDER BY id;
```
