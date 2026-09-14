# Config Center service-token rotation Job

This component contains the restricted automation boundary for service-token rotation.

## Build

The image must be built from the kubernetes repository root because the script imports the shared component runtime:

```bash
docker build -f components/config-center-token-rotation/Dockerfile \
  -t <registry>/kubernetes-tools:config-token-rotation-<immutable-tag> .
```

Push it to the approved registry, then replace the placeholder image in `cronjob.yaml` with the immutable digest. Do not use `latest`.

## Security boundary

- The Job receives only an already-issued operator token from Secret `config-center-operator`.
- It never receives a Casdoor password, admin JWT, OpenBao root token, or Pangolin credential.
- The operator token is restricted to its own environment and cannot issue another operator token.
- `CronJob.spec.suspend` remains `true` until an immutable image is published and a manual Job completes the full rotation/rollback drill.
- `concurrencyPolicy: Forbid` prevents overlapping rotations.

The rotation executable is fail-closed: it requires the selector Secret's `config-center/service-token-ids` annotation, verifies each newly issued token through `GetKey`, updates the selector, rolls consumers, and only then revokes the old token. Any failed stage stops before revocation or leaves an explicit retry condition.
