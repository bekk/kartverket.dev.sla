# Kubernetes manifests

Two namespaces:

- `ns-backstage-db` (`k8s/db/`) — in-cluster Postgres for Backstage (`StatefulSet` + headless `Service` + init-SQL `ConfigMap`).
- `ns-backstage` (`k8s/app/`) — the Backstage app itself (frontend + backend in one image, see `packages/backend/Dockerfile`).

This is currently a **smoke test**: the app is deployed with `app-config.kubernetes.yaml` (loaded
instead of `app-config.production.yaml`), which wires up the database, an Entra ID app registration
(shared by sign-in, regelrett-schemas, and security-metrics), and regelrett — all pointed at what
actually exists in this cluster/tenant. Google/GitHub sign-in and the other integrations in
`app-config.production.yaml` are not configured yet. `sikkerhetsmetrikker.baseUrl` is a known gap:
`security-metrics-backend` requires it at startup too, but there's no `sikkerhetsmetrikker` service
in this cluster to point it at.

## Secrets

Secrets are not committed. Copy each `*.env.example` in `k8s/secrets/` to a same-named `.env` file
(gitignored) and fill in the values, then create the actual Kubernetes secrets from them.

1. **`postgres.env`** (from `postgres.env.example`) — the Postgres superuser password and the
   `backstage` role's password (`APP_DB_PASSWORD`). Generate a password with `openssl rand -hex 24`.

   ```sh
   kubectl create namespace ns-backstage-db
   kubectl create secret generic secret-backstage-postgres \
     --namespace ns-backstage-db \
     --from-env-file k8s/secrets/postgres.env
   ```

2. **`backstage-db.env`** (from `backstage-db.env.example`) — how the app connects to that database.
   `POSTGRES_PASSWORD` here must match `APP_DB_PASSWORD` above.

   ```sh
   kubectl create namespace ns-backstage
   kubectl create secret generic secret-backstage-db \
     --namespace ns-backstage \
     --from-env-file k8s/secrets/backstage-db.env
   ```

3. **`auth.env`** (from `auth.env.example`) — the Entra ID (Azure AD) app registration used both
   for Microsoft sign-in and for the service-to-service calls `regelrett-schemas-backend` and
   `security-metrics-backend` make eagerly at startup (not just when someone signs in — omitting
   these blocks the backend from ever becoming ready), plus regelrett's own client ID.

   ```sh
   kubectl create secret generic secret-backstage-auth \
     --namespace ns-backstage \
     --from-env-file k8s/secrets/auth.env
   ```

## Deploying

Apply manifester


```sh
# DB
kubectl apply -f k8s/db/namespace.yaml
kubectl apply -f k8s/db/configmap-initdb.yaml
kubectl apply -f k8s/db/postgres.yaml

# App — namespace/service first, deployment uses whatever image was last `kubectl set image`'d
kubectl apply -f k8s/app/namespace.yaml
kubectl apply -f k8s/app/service.yaml
kubectl apply -f k8s/app/deployment.yaml
```

Build and push image

```sh
yarn install && yarn tsc && yarn build:backend

gcloud auth configure-docker europe-north1-docker.pkg.dev
PROJECT=gcp-fleks-grafanaslo
IMAGE=europe-north1-docker.pkg.dev/$PROJECT/spire-grafana-slo/backstage:$(date +%Y%m%d-%H%M)-$(git rev-parse --short=7 HEAD)
echo $IMAGE

docker buildx build --platform linux/amd64 -f packages/backend/Dockerfile -t "$IMAGE" --push .
```


`k8s/app/deployment.yaml` ships with `image: IMAGE_PLACEHOLDER` — don't hand-edit it. After the
first `kubectl apply -f k8s/app/deployment.yaml`, point it at a real image with:


```sh
kubectl set image deployment/deployment-backstage backstage=$IMAGE -n ns-backstage
```

The tag applied this way isn't reflected back into the committed YAML — that's expected until
there's a CI/CD flow to write it back.

Then smoke-test with a port-forward (matches the `BASE_URL=http://localhost:7007` default in
`k8s/app/deployment.yaml`):

```sh
kubectl port-forward -n ns-backstage svc/service-backstage 7007:7007
```
