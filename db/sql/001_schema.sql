CREATE TABLE IF NOT EXISTS devices (
    id            BIGSERIAL PRIMARY KEY,
    resource_type TEXT NOT NULL,
    resource_id   TEXT NOT NULL,
    hue_type      TEXT NOT NULL,
    mac           TEXT,
    name          TEXT NOT NULL,
    room          TEXT,
    modelid       TEXT,
    productname   TEXT,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_devices_resource UNIQUE (resource_type, resource_id)
);

COMMENT ON TABLE devices IS 'One row per logical Hue resource (light or sensor). Static metadata only; measurements live in readings.';
COMMENT ON COLUMN devices.resource_type IS 'Which bridge endpoint this came from: light or sensor.';
COMMENT ON COLUMN devices.resource_id IS 'Id as returned by the bridge. NOT unique across endpoints: light 6 and sensor 6 are different devices, hence the composite key with resource_type.';
COMMENT ON COLUMN devices.hue_type IS 'Bridge type field: ZLLTemperature, ZLLPresence, ZLLLightLevel, ZLLSwitch, Daylight, Extended color light, etc.';
COMMENT ON COLUMN devices.mac IS 'uniqueid truncated at the first dash. The three logical sensors of one physical motion sensor share this value. NULL for Daylight, a virtual sensor with no uniqueid.';
COMMENT ON COLUMN devices.name IS 'Name as reported by the bridge. Often unhelpful for sibling sensors, e.g. "Hue temperature sensor 1" - see room.';
COMMENT ON COLUMN devices.room IS 'Human-meaningful location. Populated by the poller from the ZLLPresence sibling sharing this mac; the bridge groups do not list these sensors. NULL when unresolvable.';
COMMENT ON COLUMN devices.modelid IS 'Hardware model, e.g. SML003, LCA006.';
COMMENT ON COLUMN devices.productname IS 'Marketing product name, e.g. "Hue temperature sensor".';
COMMENT ON COLUMN devices.last_seen_at IS 'Updated on every poll in which the bridge still returns this device. A stale value means the device vanished from the bridge.';

CREATE INDEX IF NOT EXISTS idx_devices_mac ON devices (mac);

COMMENT ON INDEX idx_devices_mac IS 'Supports sibling lookup by mac when the poller resolves room.';

CREATE TABLE IF NOT EXISTS readings (
    id          BIGSERIAL PRIMARY KEY,
    device_pk   BIGINT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    metric_name TEXT NOT NULL,
    value_raw   DOUBLE PRECISION,
    value       DOUBLE PRECISION,
    unit        TEXT,
    raw_state   JSONB,
    measured_at TIMESTAMPTZ NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_reading UNIQUE (device_pk, metric_name, measured_at)
);

COMMENT ON TABLE readings IS 'One row per (device, metric, measurement time). Long format: new metrics need no DDL.';
COMMENT ON COLUMN readings.metric_name IS 'temperature_c, lightlevel, dark, daylight, presence, buttonevent, battery, reachable, on, bri, ct, hue, sat.';
COMMENT ON COLUMN readings.value_raw IS 'Exactly the number the bridge returned, unconverted: 2762 for temperature, 14849 for lightlevel.';
COMMENT ON COLUMN readings.value IS 'Canonical unit for querying: temperature in degC, booleans as 0/1. Equals value_raw where no conversion applies.';
COMMENT ON COLUMN readings.unit IS 'degC, lux_log, percent, bool, or NULL. lux_log means value is Hue log scale; lux = 10 ^ ((value - 1) / 10000).';
COMMENT ON COLUMN readings.raw_state IS 'Verbatim state (or config) object from that poll, so nothing is lost to the column mapping.';
COMMENT ON COLUMN readings.measured_at IS 'When the sensor reported, from state.lastupdated. Config-derived metrics (battery, reachable) have no lastupdated, so the poller supplies poll time truncated to the hour, capping them at one row per hour.';
COMMENT ON COLUMN readings.recorded_at IS 'When the poller wrote the row. Differs from measured_at whenever a sensor has not changed since the previous poll.';
COMMENT ON CONSTRAINT uq_reading ON readings IS 'Dedup key. With INSERT ... ON CONFLICT DO NOTHING, re-polling an unchanged sensor is a no-op, so storage grows only when data changes and poll frequency is free.';

CREATE INDEX IF NOT EXISTS idx_readings_measured_at ON readings (measured_at);
CREATE INDEX IF NOT EXISTS idx_readings_device_metric_time ON readings (device_pk, metric_name, measured_at DESC);

CREATE OR REPLACE VIEW readings_v AS
SELECT r.measured_at,
       r.recorded_at,
       d.resource_type,
       d.resource_id,
       d.hue_type,
       d.mac,
       d.name                   AS device_name,
       COALESCE(d.room, d.name) AS room,
       r.metric_name,
       r.value,
       r.value_raw,
       r.unit,
       r.raw_state
FROM readings r
         JOIN devices d ON d.id = r.device_pk;

COMMENT ON VIEW readings_v IS 'Readings pre-joined to device metadata so Grafana panels need no join. room falls back to device name when unresolved.';
