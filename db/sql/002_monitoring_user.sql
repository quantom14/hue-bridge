CREATE ROLE grafana_ro LOGIN PASSWORD :'grafana_ro_password';

GRANT CONNECT ON DATABASE :"postgres_db" TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO grafana_ro;

COMMENT ON ROLE grafana_ro IS 'Read-only access for Grafana.';
