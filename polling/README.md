# polling

Reads the Hue bridge and writes to Postgres. One run per invocation; the
`hue-polling.timer` unit handles scheduling.

## What a run does

1. `GET /lights`, `/sensors`, `/groups` from the bridge
2. Upserts every device into `devices`, resolving `room`
3. Extracts metrics and inserts the ones that are actually new

Expected output:

```
INFO bridge: 5 lights, 8 sensors
INFO offered 50 rows, inserted 3
```

Offered far exceeding inserted is normal — that is deduplication working, not
an error. `nothing changed` is also a healthy result.

## Monitoring

```bash
systemctl status hue-polling.timer          # is it scheduled
systemctl list-timers hue-polling.timer     # last run, next run
journalctl -t hue-polling --since today     # poller output only
journalctl -u hue-polling.service -f        # follow, incl. systemd's own lines
journalctl -u hue-polling.service -p err    # failures only
```

`-t hue-polling` filters on `SyslogIdentifier`, so it excludes systemd's
start/stop noise. Useful when you only care what the poller said.

Force a run without waiting for the timer:

```bash
sudo systemctl start hue-polling.service
```

Note `Type=oneshot`: the unit is *inactive (dead)* between runs. That is
correct, not a failure. `systemctl status hue-polling.service` showing
`Active: inactive (dead)` with a recent successful exit is what healthy looks
like. Check the timer, not the service, to confirm scheduling.

## Health checks

Has anything arrived recently?

```sql
SELECT max(measured_at) AS newest, now() - max(measured_at) AS age
FROM readings;
```

What is each device doing?

```sql
SELECT room, device_name, metric_name, value, unit, measured_at
FROM readings_v
WHERE metric_name IN ('temperature_c', 'battery')
ORDER BY room, metric_name;
```

Row growth per day — if this climbs steadily for metrics that should be
static, deduplication has stopped working:

```sql
SELECT date_trunc('day', measured_at) AS day, metric_name, count(*)
FROM readings
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC
LIMIT 20;
```

Batteries, in the order they will need replacing:

```sql
SELECT DISTINCT ON (device_pk) room, device_name, value AS battery_pct, measured_at
FROM readings_v
JOIN readings USING (metric_name)
WHERE metric_name = 'battery'
ORDER BY device_pk, measured_at DESC;
```

## Troubleshooting

**Unit fails immediately, `KeyError: 'HUE_USERNAME'`**
The `.env` is missing or unreadable by the service user. Required variables
are read with a subscript deliberately, so the process dies loudly rather
than running half-configured.

**`bridge error on /sensors: {'type': 1, ...}`**
The API token is invalid. The bridge reports auth failures as HTTP 200 with
an error body, so the poller checks for that explicitly. Re-pair to get a new
token.

**Connection refused to Postgres**
Check `PGPORT` matches the host-side port in `docker-compose.yml`. The
container listens on 5432 internally regardless of what it is mapped to.

**`No such file or directory` on the interpreter**
Sandboxing. The repo lives under `/home`, so the unit sets
`ProtectHome=read-only`; `ProtectHome=true` would hide the code from the
service. Related: `PYTHONDONTWRITEBYTECODE=1` is set because Python cannot
write `__pycache__` into a read-only home.

**Timer scheduled but never fires after a reboot**
`Persistent=true` should cover this. Confirm with
`systemctl is-enabled hue-polling.timer`.

## Behaviour worth knowing

**Deduplication.** Sensors expose `state.lastupdated`, which becomes
`measured_at`; the unique constraint makes re-polling an unchanged sensor a
no-op. Lights have no timestamp anywhere, and `battery`/`reachable` live in
`config` which also has none — for those the poller loads the last stored
value and writes only on change. Consequence: the poll interval is free.
Polling every minute costs no extra storage.

**`buttonevent` is sampled, not complete.** Presses between polls are lost
and the bridge keeps no history to recover them.

**The `Daylight` sensor yields nothing** until configured in the Hue app. It
reports `lastupdated: "none"`, which the poller skips.

**Timestamps are UTC.** `state.lastupdated` carries no offset even though the
bridge separately reports local time. It is parsed as UTC.

**Room resolution is best-effort**, in this order: the `ZLLPresence` sibling
sharing a `mac`; Room group membership; then `NULL`, where `readings_v` falls
back to the device name. A poll that fails to resolve a room will not erase
one already stored.

## Changing the poll interval

Edit `OnUnitActiveSec` in `systemd/hue-polling.timer`, then:

```bash
sudo cp systemd/hue-polling.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart hue-polling.timer
```

## Adding a metric

No schema change needed — `readings` is long-format. Add a branch in
`extract_metrics` and it starts landing on the next run. Give it a
`measured_at` only if the bridge supplies a real timestamp for it; otherwise
pass `None` and change detection handles it.