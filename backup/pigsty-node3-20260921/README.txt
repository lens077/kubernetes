Backup scope: requested Pigsty roles/permissions and alerting/observability/Gatus configuration.
Created: 2026-09-21
Excluded: plaintext credentials, Gatus sqlite history, Victoria metrics/logs/traces data, application data, Docker volumes.
PostgreSQL SQL uses pg_dumpall --globals-only --no-role-passwords.
Alertmanager webhook URLs and all credential values are redacted.
