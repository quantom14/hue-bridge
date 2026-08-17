#!/usr/bin/env python3
"""Poll a Philips Hue bridge and persist readings to Postgres.

Run as a systemd oneshot on a timer. Each run is independent: it upserts
device metadata, then inserts any readings that are actually new.

Two dedup strategies, because the bridge gives measurement times for some
things and not others:

  * Sensors expose state.lastupdated. That becomes measured_at, and the
    unique constraint on (device, metric, measured_at) makes re-polling an
    unchanged sensor a no-op.

  * Lights and config fields (battery, reachable) have no timestamp at all.
    For those the poller reads the last stored value and writes only when it
    has changed, so an untouched lamp does not add a row every five minutes.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
import requests

log = logging.getLogger("hue-poller")

BRIDGE_IP = os.environ["HUE_BRIDGE_IP"]
HUE_USERNAME = os.environ["HUE_USERNAME"]
PG_CONN = dict(
    host=os.environ["HUE_PGHOST"],
    port=os.environ["HUE_PGPORT"],
    dbname=os.environ["HUE_PGDATABASE"],
    user=os.environ["HUE_PGUSER"],
    password=os.environ["HUE_PGPASSWORD"],
)
TIMEOUT = float(os.environ.get("HUE_TIMEOUT", "10"))

BASE = f"http://{BRIDGE_IP}/api/{HUE_USERNAME}"


# --------------------------------------------------------------------------
# Bridge
# --------------------------------------------------------------------------


def fetch(resource: str) -> dict:
    resp = requests.get(f"{BASE}/{resource}", timeout=TIMEOUT)
    resp.raise_for_status()
    body = resp.json()
    # The bridge reports auth and other failures as HTTP 200 with an error list.
    if isinstance(body, list) and body and "error" in body[0]:
        raise RuntimeError(f"bridge error on /{resource}: {body[0]['error']}")
    return body


def parse_hue_ts(value) -> datetime | None:
    """state.lastupdated is UTC, no offset, and is the string 'none' when unset."""
    if not value or value == "none":
        return None
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def mac_of(resource: dict) -> str | None:
    """uniqueid up to the first dash. Siblings of one physical device share it."""
    uid = resource.get("uniqueid")
    return uid.split("-")[0] if uid else None


# --------------------------------------------------------------------------
# Devices
# --------------------------------------------------------------------------


def build_devices(lights: dict, sensors: dict, groups: dict) -> list[dict]:
    """Flatten both endpoints into device rows, resolving a room for each.

    Sensors: the bridge names siblings uselessly ("Hue temperature sensor 1"),
    so take the name of the ZLLPresence sibling sharing the same MAC.
    Lights: take the name of the Room group that contains them.
    """
    presence_name_by_mac = {
        mac_of(s): s.get("name")
        for s in sensors.values()
        if s.get("type") == "ZLLPresence" and mac_of(s)
    }

    # Room groups list their lights, and occasionally their sensors. Motion
    # sensors are usually absent, which is why the MAC fallback above exists,
    # but switches do show up here.
    room_by_light_id, room_by_sensor_id = {}, {}
    for group in groups.values():
        if group.get("type") != "Room":
            continue
        for light_id in group.get("lights", []):
            room_by_light_id[light_id] = group.get("name")
        for sensor_id in group.get("sensors", []):
            room_by_sensor_id[sensor_id] = group.get("name")

    devices = []

    for rid, light in lights.items():
        devices.append(
            {
                "resource_type": "light",
                "resource_id": rid,
                "hue_type": light.get("type", "unknown"),
                "mac": mac_of(light),
                "name": light.get("name", f"light {rid}"),
                "room": room_by_light_id.get(rid),
                "modelid": light.get("modelid"),
                "productname": light.get("productname"),
            }
        )

    for rid, sensor in sensors.items():
        mac = mac_of(sensor)
        devices.append(
            {
                "resource_type": "sensor",
                "resource_id": rid,
                "hue_type": sensor.get("type", "unknown"),
                "mac": mac,
                "name": sensor.get("name", f"sensor {rid}"),
                "room": presence_name_by_mac.get(mac) or room_by_sensor_id.get(rid),
                "modelid": sensor.get("modelid"),
                "productname": sensor.get("productname"),
            }
        )

    return devices


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------


def _num(value) -> float | None:
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return None


def extract_metrics(
    resource_type: str, resource: dict, poll_time: datetime
) -> list[dict]:
    """Return metric dicts for one device.

    measured_at is None for metrics the bridge gives no timestamp for; the
    caller resolves those by change detection.
    """
    state = resource.get("state") or {}
    config = resource.get("config") or {}
    metrics: list[dict] = []

    def add(name, raw, value, unit, measured_at, blob):
        metrics.append(
            {
                "metric_name": name,
                "value_raw": _num(raw),
                "value": value,
                "unit": unit,
                "measured_at": measured_at,
                "raw_state": json.dumps(blob),
            }
        )

    if resource_type == "sensor":
        measured = parse_hue_ts(state.get("lastupdated"))
        hue_type = resource.get("type")

        # Daylight is a virtual sensor and is null until configured.
        if measured is not None:
            if hue_type == "ZLLTemperature" and state.get("temperature") is not None:
                raw = state["temperature"]
                add("temperature_c", raw, raw / 100.0, "degC", measured, state)

            elif hue_type == "ZLLLightLevel" and state.get("lightlevel") is not None:
                raw = state["lightlevel"]
                add("lightlevel", raw, float(raw), "lux_log", measured, state)
                for flag in ("dark", "daylight"):
                    if state.get(flag) is not None:
                        add(
                            flag,
                            state[flag],
                            _num(state[flag]),
                            "bool",
                            measured,
                            state,
                        )

            elif hue_type == "ZLLPresence" and state.get("presence") is not None:
                add(
                    "presence",
                    state["presence"],
                    _num(state["presence"]),
                    "bool",
                    measured,
                    state,
                )

            elif hue_type == "ZLLSwitch" and state.get("buttonevent") is not None:
                # Sampled, not complete: presses between polls are missed.
                raw = state["buttonevent"]
                add("buttonevent", raw, float(raw), None, measured, state)

        # config has no timestamp -> change detection
        if config.get("battery") is not None:
            raw = config["battery"]
            add("battery", raw, float(raw), "percent", None, config)
        if config.get("reachable") is not None:
            add(
                "reachable",
                config["reachable"],
                _num(config["reachable"]),
                "bool",
                None,
                config,
            )

    else:  # light: no lastupdated anywhere -> change detection for everything
        if state.get("reachable") is not None:
            add(
                "reachable",
                state["reachable"],
                _num(state["reachable"]),
                "bool",
                None,
                state,
            )
        if state.get("on") is not None:
            add("on", state["on"], _num(state["on"]), "bool", None, state)
        for field, unit in (
            ("bri", None),
            ("ct", "mired"),
            ("hue", None),
            ("sat", None),
        ):
            if state.get(field) is not None:
                add(field, state[field], float(state[field]), unit, None, state)

    return metrics


# --------------------------------------------------------------------------
# Persistence
# --------------------------------------------------------------------------

UPSERT_DEVICE = """
                INSERT INTO devices (resource_type, resource_id, hue_type, mac, name, room, modelid, productname)
                VALUES (%(resource_type)s, %(resource_id)s, %(hue_type)s, %(mac)s, %(name)s, %(room)s,
                        %(modelid)s, %(productname)s)
                ON CONFLICT (resource_type, resource_id) DO UPDATE
                    SET hue_type     = EXCLUDED.hue_type,
                        mac          = EXCLUDED.mac,
                        name         = EXCLUDED.name,
                        room         = COALESCE(EXCLUDED.room, devices.room),
                        modelid      = EXCLUDED.modelid,
                        productname  = EXCLUDED.productname,
                        last_seen_at = now()
                RETURNING id \
                """

# DISTINCT ON is Postgres-specific: one row per group, picked by ORDER BY.
LAST_VALUES = """
              SELECT DISTINCT ON (device_pk, metric_name) device_pk, metric_name, value
              FROM readings
              ORDER BY device_pk, metric_name, measured_at DESC \
              """

# noinspection SqlNoDataSourceInspection,SqlResolve
INSERT_READING = """
                 INSERT INTO readings (device_pk, metric_name, value_raw, value, unit, raw_state, measured_at)
                 VALUES %s
                 ON CONFLICT (device_pk, metric_name, measured_at) DO NOTHING \
                 """


def upsert_devices(cur, devices: list[dict]) -> dict[tuple[str, str], int]:
    pk_by_resource = {}
    for device in devices:
        cur.execute(UPSERT_DEVICE, device)
        pk_by_resource[(device["resource_type"], device["resource_id"])] = (
            cur.fetchone()[0]
        )
    return pk_by_resource


def load_last_values(cur) -> dict[tuple[int, str], float | None]:
    cur.execute(LAST_VALUES)
    return {(row[0], row[1]): row[2] for row in cur.fetchall()}


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(message)s",  # systemd adds its own timestamps
    )

    poll_time = datetime.now(timezone.utc)
    lights = fetch("lights")
    sensors = fetch("sensors")
    groups = fetch("groups")
    log.info("bridge: %d lights, %d sensors", len(lights), len(sensors))

    devices = build_devices(lights, sensors, groups)

    conn = psycopg2.connect(**PG_CONN)
    try:
        with conn, conn.cursor() as cur:
            pk_by_resource = upsert_devices(cur, devices)
            last_values = load_last_values(cur)

            rows = []
            for resource_type, resources in (("light", lights), ("sensor", sensors)):
                for rid, resource in resources.items():
                    device_pk = pk_by_resource[(resource_type, rid)]
                    for metric in extract_metrics(resource_type, resource, poll_time):
                        measured_at = metric["measured_at"]
                        if measured_at is None:
                            # No bridge timestamp: write only on change.
                            key = (device_pk, metric["metric_name"])
                            if (
                                key in last_values
                                and last_values[key] == metric["value"]
                            ):
                                continue
                            measured_at = poll_time
                        rows.append(
                            (
                                device_pk,
                                metric["metric_name"],
                                metric["value_raw"],
                                metric["value"],
                                metric["unit"],
                                metric["raw_state"],
                                measured_at,
                            )
                        )

            if rows:
                psycopg2.extras.execute_values(cur, INSERT_READING, rows)
                log.info("offered %d rows, inserted %d", len(rows), cur.rowcount)
            else:
                log.info("nothing changed")
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        log.exception("poll failed")
        sys.exit(1)
