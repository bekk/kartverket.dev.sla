#!/usr/bin/env bash
# Setter opp Workload Identity Federation for GitHub Actions i GCP-prosjektet.
# Idempotent: kjør den om igjen uten å lage duplikater.
set -euo pipefail

# Poolen deles med andre repoer i samme prosjekt. Provideren og service-kontoen
# er Backstages egne, slik at et annet repo aldri kan låne denne identiteten.
pool=${pool:-github}
provider=${provider:-backstage-oidc}
sa=${sa:-sa-github-deploy-backstage}
environment=${environment:-gcp-backstage}

cd "$(git rev-parse --show-toplevel)"

for verktoy in gcloud yq git; do
  command -v "$verktoy" >/dev/null || { echo "Mangler $verktoy." >&2; exit 1; }
done

config=gcp-config.yaml
app=$(yq -r '.app' "$config")
region=$(yq -r '.gcp.region' "$config")
project_id=$(yq -r '.gcp.project_id' "$config")
ar_repo=$(yq -r '.gcp.repo' "$config")

# Repoet utledes av git-remoten, slik at attributt-betingelsen ikke kan
# skrives feil for hånd. Både SSH- og HTTPS-formen håndteres.
gh_repo=$(git remote get-url origin)
gh_repo=${gh_repo#git@github.com:}
gh_repo=${gh_repo#ssh://git@github.com/}
gh_repo=${gh_repo#https://github.com/}
gh_repo=${gh_repo%.git}
case "$gh_repo" in
  */*) ;;
  *) echo "Klarte ikke lese «eier/repo» ut av git-remoten: $gh_repo" >&2; exit 1 ;;
esac

project_number=$(gcloud projects describe "$project_id" --format='value(projectNumber)')
sa_email="${sa}@${project_id}.iam.gserviceaccount.com"
vilkaar="assertion.repository == '${gh_repo}'"
provider_sti="projects/${project_number}/locations/global/workloadIdentityPools/${pool}/providers/${provider}"
medlem="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool}/attribute.repository/${gh_repo}"

cat <<OPPSUMMERING

  Prosjekt        $project_id ($project_number)
  GitHub-repo     $gh_repo
  Pool            $pool (deles med andre repoer)
  Provider        $provider (bare dette repoet)
  Service-konto   $sa_email
  Registry-repo   $ar_repo i $region
  App             $app

OPPSUMMERING

if [ "${1:-}" != "-y" ]; then
  printf 'Fortsette? [j/N] '
  read -r svar
  case "$svar" in [jJyY]*) ;; *) echo "Avbrutt."; exit 1 ;; esac
fi

echo "==> API-er"
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  --project "$project_id"

echo "==> Workload identity pool"
gcloud iam workload-identity-pools describe "$pool" \
  --location global --project "$project_id" >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools create "$pool" \
       --location global --project "$project_id" \
       --display-name "GitHub Actions"

echo "==> OIDC-provider"
if gcloud iam workload-identity-pools providers describe "$provider" \
     --location global --workload-identity-pool "$pool" \
     --project "$project_id" >/dev/null 2>&1; then
  # Provideren finnes. Betingelsen er sikkerhetsgrensen, så den kontrolleres
  # i stedet for å antas – en «describe» ville ellers skjult en feil verdi.
  naa=$(gcloud iam workload-identity-pools providers describe "$provider" \
          --location global --workload-identity-pool "$pool" \
          --project "$project_id" --format='value(attributeCondition)')
  if [ "$naa" != "$vilkaar" ]; then
    echo "    Betingelsen avviker. Oppdaterer."
    echo "      var:  ${naa:-(tom)}"
    echo "      blir: $vilkaar"
    gcloud iam workload-identity-pools providers update-oidc "$provider" \
      --location global --workload-identity-pool "$pool" \
      --project "$project_id" --attribute-condition "$vilkaar"
  fi
else
  gcloud iam workload-identity-pools providers create-oidc "$provider" \
    --location global --workload-identity-pool "$pool" \
    --project "$project_id" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.environment=assertion.environment" \
    --attribute-condition "$vilkaar"
fi

echo "==> Service-konto"
gcloud iam service-accounts describe "$sa_email" --project "$project_id" >/dev/null 2>&1 \
  || gcloud iam service-accounts create "$sa" --project "$project_id" \
       --display-name "GitHub Actions deploy (Backstage)"

echo "==> Binding mot repoet"
gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
  --project "$project_id" --role roles/iam.workloadIdentityUser \
  --member "$medlem" --condition=None >/dev/null

echo "==> Roller"
# Registry-repoet må finnes. Uten det feiler bindingen med en melding om et
# repo, ikke om at det ikke er opprettet ennå.
if ! gcloud artifacts repositories describe "$ar_repo" \
       --location "$region" --project "$project_id" >/dev/null 2>&1; then
  echo "    Artifact Registry-repoet «${ar_repo}» finnes ikke i $region." >&2
  exit 1
fi
gcloud artifacts repositories add-iam-policy-binding "$ar_repo" \
  --location "$region" --project "$project_id" \
  --member "serviceAccount:${sa_email}" \
  --role roles/artifactregistry.writer >/dev/null
gcloud projects add-iam-policy-binding "$project_id" \
  --member "serviceAccount:${sa_email}" \
  --role roles/container.developer --condition=None >/dev/null

cat <<RESULTAT

Ferdig.

Legg inn i GitHub under Settings -> Environments -> $environment:

  GCP_PROJECT_ID                  $project_id
  GCP_WORKLOAD_IDENTITY_PROVIDER  $provider_sti
  GCP_SERVICE_ACCOUNT             $sa_email

Eller med gh, kjørt fra repo-roten:

  gh variable set GCP_PROJECT_ID --env $environment --body '$project_id'
  gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --env $environment --body '$provider_sti'
  gh variable set GCP_SERVICE_ACCOUNT --env $environment --body '$sa_email'

Deployen trenger ingen Secrets i GitHub. Secretene i klyngen lages én gang med
kubectl, se k8s/README.md, og manifestene refererer dem bare ved navn.

Environmentet må finnes i GitHub før «gh variable set --env» virker.
RESULTAT