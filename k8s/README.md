# Kubernetes manifests

Backstage runs at <https://backstage.slo.fleks.dev>, configured by `app-config.kubernetes.yaml`
instead of `app-config.production.yaml`.

| Directory | Namespace | Contents | Deployed by |
| --- | --- | --- | --- |
| `k8s/app/` | `ns-backstage` | Backstage, its route and NetworkPolicy | CI on merge to `main` |
| `k8s/db/` | `ns-backstage-db` | Postgres (`StatefulSet`, headless `Service`, init SQL) | Hand |
| `k8s/gateway/` | `ns-gateway` | Shared Gateway for `*.slo.fleks.dev` | Hand |

Known gap: `security-metrics-backend` needs `sikkerhetsmetrikker.baseUrl` at startup, but there
is no such service in this cluster.

## Secrets

Copy each `k8s/secrets/*.env.example` to a gitignored `.env` file, fill it in, and create the secret.

1. **`postgres.env`**: the superuser password and the `backstage` role's `APP_DB_PASSWORD`
   (`openssl rand -hex 24`).

   ```sh
   kubectl create namespace ns-backstage-db
   kubectl create secret generic secret-backstage-postgres -n ns-backstage-db --from-env-file k8s/secrets/postgres.env
   ```

2. **`backstage-db.env`**: how the app connects. `POSTGRES_PASSWORD` must match `APP_DB_PASSWORD`.

   ```sh
   kubectl create namespace ns-backstage
   kubectl create secret generic secret-backstage-db -n ns-backstage --from-env-file k8s/secrets/backstage-db.env
   ```

3. **`auth.env`**: Entra ID, GitHub OAuth and plugin client IDs.

   ```sh
   kubectl create secret generic secret-backstage-auth -n ns-backstage --from-env-file k8s/secrets/auth.env
   ```

   - The Entra app (`ENTRA_WEB_APP_ID`) handles sign-in, the Graph catalog sync and the startup
     calls from `regelrett-schemas-backend` and `security-metrics-backend`. It needs Graph
     permissions `User.Read.All` and `GroupMember.Read.All`, and the Web redirect URI
     `https://backstage.slo.fleks.dev/api/auth/microsoft/handler/frame`.
   - The GitHub OAuth App (`AUTH_GITHUB_CLIENT_*`) is used by `/catalog-creator` and the
     risk-scorecard plugin. Homepage `https://backstage.slo.fleks.dev`, callback
     `https://backstage.slo.fleks.dev/api/auth/github/handler/frame`. The `public_repo` scope
     covers public repos, including opening PRs.

## Deploying

`.github/workflows/deploy-gcp.yml` builds the image and applies `k8s/app/` on merge to `main`.
It replaces `IMAGE_PLACEHOLDER` in `deployment.yaml`, so don't hand-edit it.

The database is applied by hand:

```sh
kubectl apply -f k8s/db/namespace.yaml
kubectl apply -f k8s/db/
```

## Domain and Gateway

`k8s/gateway/` is a shared GKE Gateway for `*.slo.fleks.dev`. Each app attaches its own
`HTTPRoute`. Everything below was created once by hand; rerun a step if its resource is deleted.

1. DNS zone. `slo.fleks.dev` is delegated from `fleks.dev`, so we manage the records.

   ```sh
   gcloud dns managed-zones create zone-slo-fleks-dev --dns-name slo.fleks.dev. --visibility public
   ```

2. Static IP and records. One global IP, with each hostname pointing to it.

   ```sh
   gcloud compute addresses create ip-gateway-external --global
   gcloud dns record-sets create backstage.slo.fleks.dev. --zone zone-slo-fleks-dev --type A --rrdatas <IP>
   gcloud dns record-sets create regelrett.slo.fleks.dev. --zone zone-slo-fleks-dev --type A --rrdatas <IP>
   ```

3. Certificate. A Google-managed wildcard, validated through a CNAME in our zone. The Gateway's
   `networking.gke.io/certmap` annotation points to the map.

   ```sh
   gcloud certificate-manager dns-authorizations create dnsauth-slo-fleks-dev --domain slo.fleks.dev
   # add the CNAME from `dns-authorizations describe dnsauth-slo-fleks-dev` to zone-slo-fleks-dev
   gcloud certificate-manager certificates create cert-slo-fleks-dev --domains '*.slo.fleks.dev' --dns-authorizations dnsauth-slo-fleks-dev
   gcloud certificate-manager maps create certmap-slo-fleks-dev
   gcloud certificate-manager maps entries create certmapentry-slo-fleks-dev --map certmap-slo-fleks-dev --certificates cert-slo-fleks-dev --hostname '*.slo.fleks.dev'
   ```

4. Gateway. Creates the load balancer and an HTTP-to-HTTPS redirect.

   ```sh
   kubectl apply -f k8s/gateway/namespace.yaml
   kubectl apply -f k8s/gateway/
   ```

## NetworkPolicy

The cluster enforces NetworkPolicy (GKE Dataplane V2). Both namespaces deny all ingress by default.

- `ns-backstage` allows Google's load balancer (`35.191.0.0/16`, `130.211.0.0/22`) on port 7007.
- `ns-backstage-db` allows pods labeled `app.kubernetes.io/name: backstage` in `ns-backstage` on
  port 5432.

The pod label `app.kubernetes.io/name: backstage` is matched by the database rule here and by
`netpol-allow-backstage-to-regelrett` in Regelrett.sla. If the label in `deployment.yaml`
changes, update both, or the traffic is dropped and shows up as a connection timeout rather than
an auth or "connection refused" error.
