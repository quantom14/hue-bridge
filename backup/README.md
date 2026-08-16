# backup

Nightly `pg_dump` of the `hue` database. Mirrors the Paperless backup script:
same staging-then-rename publish, same `LAST_BACKUP_OK` marker, same
count-based retention, same log rotation. An offsite job on another machine
pulls from `backups/`.

## Layout

```
backup/
├── backup.sh
├── backup.log            (rotated at 10 MB, gitignored)
└── backups/              (gitignored)
    ├── LAST_BACKUP_OK    contains the name of the newest good backup
    └── backup_<TS>/
        └── db-<TS>.sql.gz
```

No volume archives, unlike Paperless: the `pgdata` volume contains nothing
the dump does not already hold, and there is no media directory.

## Monitoring

```bash
systemctl list-timers hue-backup.timer
journalctl -t hue-backup --since '7 days ago'
tail -n 40 backup/backup.log
cat backup/backups/LAST_BACKUP_OK
du -sh backup/backups/
```

Each run logs the dump size and the `readings` row count. A size that stops
growing while the count climbs means something is wrong.

The offsite job should read `LAST_BACKUP_OK` rather than picking the newest
directory: the marker is only written after a dump has passed its sanity
check, so it never points at a partial backup.

## Restoring

Into a scratch database first — never straight over live data:

```bash
docker compose exec postgres createdb -U hue hue_restore
gunzip -c backup/backups/backup_<TS>/db-<TS>.sql.gz \
  | docker compose exec -T postgres psql -U hue -d hue_restore
docker compose exec postgres psql -U hue -d hue_restore -c 'SELECT count(*) FROM readings'
```

Then drop it:

```bash
docker compose exec postgres dropdb -U hue hue_restore
```

A backup you have never restored is a hypothesis, not a backup. Do this
occasionally.

## Notes

- Backups stage in `.staging_<TS>` and are renamed on success, so a partial
  run never looks complete. Stale staging dirs are cleared at the next start.
- The dump is checked for a `COPY public.readings` block before publishing; a
  dump that succeeded but wrote no data is rejected.
- `pg_dump` runs inside the container, so the host needs no psql client and
  the dump tool can never be older than the server.
- Plain SQL rather than custom format, to match the Paperless script. It
  restores with `psql` and is greppable, at the cost of `pg_restore`'s
  selective-table extraction.
- `pg_dump` uses a repeatable-read snapshot, so the poller can keep running
  during the backup without blocking or corrupting it.
- Retention is 180 backups, not 180 days: a Pi that was off for a week keeps
  180 real backups rather than silently thinning out.
