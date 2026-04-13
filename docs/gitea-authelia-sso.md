# Gitea + Authelia SSO

Gitea uses Authelia for SSO via OAuth2/OIDC. Traefik forward-auth (`authelia-forwardauth@kubernetescrd`) also gates the Gitea ingress directly.

## URLs

- Gitea: `https://git.rtm.kubernative.io`
- Authelia: `https://authelia.rtm.kubernative.io`

---

## Setup

### Status: Already configured

The Authelia OAuth2 auth source is already active in the cluster (ID `3`, name `authelia`). Verify with:

```bash
kubectl exec -n gitea deployment/gitea -- gitea admin auth list
```

### Re-configure (if lost after Gitea reinstall)

**Option A: Script**
```bash
./scripts/setup-gitea-oauth2.sh
```

**Option B: CLI in pod**
```bash
kubectl exec -n gitea deployment/gitea -- gitea admin auth add-oauth \
  --name authelia \
  --provider openidConnect \
  --key gitea \
  --secret "<AUTHELIA_OIDC_GITEA_SECRET from .env>" \
  --auto-discover-url "https://authelia.rtm.kubernative.io/.well-known/openid-configuration" \
  --scopes "openid email profile groups" \
  --group-claim-name "groups"
```

**Option C: Manual via Gitea UI**

1. Login to Gitea as admin (`smii`)
2. Go to **Site Administration > Authentication Sources > Add Authentication Source**
3. Set:
   - **Type**: OAuth2
   - **Name**: `authelia`
   - **Provider**: OpenID Connect
   - **Client ID**: `gitea`
   - **Client Secret**: _(from `.env` `AUTHELIA_OIDC_GITEA_SECRET`)_
   - **Auto Discovery URL**: `https://authelia.rtm.kubernative.io/.well-known/openid-configuration`
   - **Scopes**: `openid email profile groups`
   - **Group claim**: `groups`

---

## Authelia OIDC Client Config

In `charts/authelia/authelia-values.yaml` under `configMap.identity_providers.oidc.clients`:

```yaml
- id: 'gitea'
  description: 'Gitea Git Repository'
  secret: 'gitea_client_secret'
  public: false
  authorization_policy: 'one_factor'
  redirect_uris:
    - 'https://git.rtm.kubernative.io/user/oauth2/authelia/callback'
  scopes:
    - openid
    - profile
    - email
    - groups
```

> Change `gitea_client_secret` to a strong random value and keep it consistent between Authelia and Gitea.

---

## User / Group Mapping

| Username | Groups | Gitea access |
|---|---|---|
| smii | admins, all _prd | Full admin (1FA) |
| grace | devops_dev | Push access (1FA) |
| henry | devops_test | Push access (1FA) |
| ivan | devops_prd | Push access (2FA required) |
| alice | homelab_dev | Push access (1FA) |
| bob | homelab_test | Push access (1FA) |
| carol | homelab_prd | Push access (2FA required) |
| dave | webapp_dev | Push access (1FA) |
| frank | webapp_prd | Push access (2FA required) |
| judy | platform_dev | Push access (1FA) |
| linda | platform_prd | Push access (2FA required) |
| viewer | viewers | Read-only (1FA) |

See `authelia-users.yml` for full credentials and `authelia-users.yml-access-control.yaml` for per-domain policies.

---

## Troubleshooting

```bash
# Authelia pod status
kubectl get pods -n authelia

# Authelia logs
kubectl logs -n authelia deployment/authelia --tail=50

# OIDC discovery endpoint
curl https://authelia.rtm.kubernative.io/.well-known/openid_configuration

# Gitea auth sources (API token required)
curl -H "Authorization: token <TOKEN>" \
  https://git.rtm.kubernative.io/api/v1/admin/auth_sources
```

**Redirect URI mismatch**: ensure the URI in Authelia exactly matches `https://git.rtm.kubernative.io/user/oauth2/authelia/callback`.

**TOTP required**: users in `*_prd` groups must complete 2FA before accessing Gitea.
All TOTP secrets are pre-registered — users are prompted for their code directly without any setup flow.
See `docs/authelia-totp.md` for all URIs and how to re-register.

**No email is sent at any point.** Authelia runs with:
- SMTP disabled
- Password reset disabled
- Notifier: filesystem (`/tmp/authelia-notifications.log`)

If Authelia writes a notification, read it from the pod:
```bash
kubectl exec -n authelia deployment/authelia -- cat /tmp/authelia-notifications.log
```
