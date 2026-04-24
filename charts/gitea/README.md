# Gitea Configuration

Gitea is deployed via ArgoCD + Helm chart (`https://dl.gitea.io/charts/ v12.4.0`).

## URLs

- Gitea: `https://git.rtm.kubernative.io`
- Authelia SSO: `https://authelia.rtm.kubernative.io`

## Admin User

| Field | Value |
|-------|-------|
| Username | `smii` |
| Password | Set in `.env` as `GITEA_ADMIN_PASSWORD` |
| Email | `admin@ovie.kubernative.io` |

Password is managed by the Gitea Helm chart's `gitea.admin` values section and applied by the `configure-gitea` init container on each restart (`GITEA_ADMIN_PASSWORD_MODE: keepUpdated`).

## SSO (Authelia OAuth2)

Gitea uses Authelia as an OAuth2/OIDC authentication source. This is **already configured** in the cluster via `gitea admin auth add-oauth`.

To verify or re-add:
```bash
# Check auth source
kubectl exec -n gitea deployment/gitea -- gitea admin auth list

# Re-add if missing
./scripts/setup-gitea-oauth2.sh
```

See `docs/gitea-authelia-sso.md` for full integration details.

## Configuration Files

| File | Purpose |
|------|---------|
| `gitea-values.yaml` | Active Helm values — committed to Git, applied by ArgoCD |
| `gitea-values.yaml.template` | Template with `${ENV_VAR}` placeholders for `generate-gitea-config.sh` |

## Active Settings

- **Database**: SQLite (no external DB required)
- **Registration**: Disabled (`DISABLE_REGISTRATION: true`)
- **SSH**: Disabled
- **Ingress**: Traefik with cert-manager TLS + Authelia forward-auth middleware
- **Persistence**: 10Gi PVC on default storage class
- **Default branch**: `main`

## ArgoCD Sync

After changing `gitea-values.yaml`, commit and push. ArgoCD auto-syncs. To force:
```bash
kubectl exec -n argocd deployment/argocd-server -- \
  argocd app sync gitea --server localhost:8080 --plaintext
```
