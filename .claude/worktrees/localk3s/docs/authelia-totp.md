# Authelia TOTP Credentials

All TOTP secrets were pre-registered via the Authelia CLI to bypass the identity-verification
one-time-code step that Authelia v4.38+ requires before allowing 2FA registration.

Secrets are stored in the Authelia SQLite database (`/config/db.sqlite3` on the PVC).
On first login, users are prompted directly for their TOTP code — no setup flow needed.

**All users share password `Homelab2024!`.**

---

## TOTP URIs

Import any of these into Google Authenticator, Authy, 1Password, etc.
To render as a QR code in the terminal: `qrencode -t UTF8 '<uri>'`

| User | Groups | Policy | TOTP URI |
|------|--------|--------|----------|
| smii | admins, all _prd | 1FA (admin) | `otpauth://totp/kubernative.io:smii?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=UNW4I3A3JILLAZHBQO5CMPI5GDZPFFPPIUCE6PJVCL3O5VPVVFJA` |
| alice | homelab_dev | 1FA | `otpauth://totp/kubernative.io:alice?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=NSSLZKSK2BXLSNS56JLYLKJWEE6CEMMI37AJB5CN3AR4HMF624WQ` |
| bob | homelab_test | 1FA | `otpauth://totp/kubernative.io:bob?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=GAMFGYPWMF4JSVNYIQTVQYJ5XMDWQUUVF647GUWWP46RDLXN57HQ` |
| carol | homelab_prd | **2FA required** | `otpauth://totp/kubernative.io:carol?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=QPMZ53AKQNL5UGQTHZIRY2NCRNMRMPO6IVXZSM6E2WNQF7OPIQMA` |
| dave | webapp_dev | 1FA | `otpauth://totp/kubernative.io:dave?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=OC46Z5V2JM6BK2CZ5QTKOYUL7FSUYA2URFA65EMI4GVHPP7VH4IA` |
| eve | webapp_test | 1FA | `otpauth://totp/kubernative.io:eve?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=KO6U6EWQ6Q3W4E5OJUHJAOWRADHRTFPVTZEDZN42CST5YIE37HYA` |
| frank | webapp_prd | **2FA required** | `otpauth://totp/kubernative.io:frank?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=IFTUYIBNOIR4SB73NLGXI5TTLAPKAXIWOO2KWWDKYMYDCKTGX4YQ` |
| grace | devops_dev | 1FA | `otpauth://totp/kubernative.io:grace?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=3YMGIXW4DPTUREMHEYGSUU7WLUQSSMNTI3OPDDVXKGTDTHNLWC3A` |
| henry | devops_test | 1FA | `otpauth://totp/kubernative.io:henry?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=ZEYEQQLR76AFIQROYUYRJWON7IESPA6PKWLRRQWIHLGJGIXPRPRQ` |
| ivan | devops_prd | **2FA required** | `otpauth://totp/kubernative.io:ivan?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=6WTVH7B65J7OPO4A55MXYE4H3MLR43ULWOHDCAGB62EOU33APIJQ` |
| judy | platform_dev | 1FA | `otpauth://totp/kubernative.io:judy?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=KN47SZHUCDQCXFX2BSLQXFA5KC3MNXA52EGSTUS57ZCOCFLTONAQ` |
| karl | platform_test | 1FA | `otpauth://totp/kubernative.io:karl?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=TP2UWSMRY3VY4QT4KM4GUNSRVTNDAT4GNNA7X3H63ZLZLRZMQTPQ` |
| linda | platform_prd | **2FA required** | `otpauth://totp/kubernative.io:linda?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=ONZ7UEVDKT7QNBFBUEY7GIMARVIRLNV72QA4E7WAA6GME6PM7G4A` |
| viewer | viewers | 1FA | `otpauth://totp/kubernative.io:viewer?algorithm=SHA1&digits=6&issuer=kubernative.io&period=30&secret=LW7QUXXR6GCQQGFASO5POWJDMLCGU6MCFMG4FD56ON5ZVAKFRNCQ` |

---

## Re-registering TOTP

If a user loses their authenticator app or the Authelia DB is wiped:

```bash
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)

# Re-generate (--force overwrites existing secret)
kubectl exec -n authelia $POD -- \
  authelia storage user totp generate <username> --config /configuration.yaml --force
```

This prints a new `otpauth://` URI. The old secret in the authenticator app will stop working.

To regenerate all users at once:
```bash
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
for user in smii alice bob carol dave eve frank grace henry ivan judy karl linda viewer; do
  echo -n "$user: "
  kubectl exec -n authelia $POD -- \
    authelia storage user totp generate $user --config /configuration.yaml --force 2>&1
done
```

---

## If the DB gets wiped (encryption key mismatch)

The Authelia secret is annotated `helm.sh/resource-policy=keep`. To mount the existing
secret without Helm regenerating keys, values use `secret.disabled: false` +
`secret.existingSecret: 'authelia'` — this mounts the pre-existing secret and skips
rendering a new Secret manifest.

If the encryption key ever mismatches the DB again:

```bash
# 1. Delete the stale DB
kubectl run authelia-db-reset --rm -i --restart=Never \
  --image=busybox \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"authelia"}}],"containers":[{"name":"authelia-db-reset","image":"busybox","command":["sh","-c","rm -f /config/db.sqlite3 && echo DELETED"],"volumeMounts":[{"name":"data","mountPath":"/config"}]}]}}' \
  -n authelia

# 2. Restart Authelia immediately (before any crashing pod recreates the DB with a wrong key)
kubectl rollout restart daemonset/authelia -n authelia
kubectl rollout status daemonset/authelia -n authelia

# 3. Re-register all TOTP secrets (run the loop above)
```

---

## Notes

- TOTP is the only 2FA method enabled (WebAuthn disabled in `authelia-values.yaml`)
- 1FA users (dev/test/admins/viewers) have TOTP registered but are not prompted for it
- `_prd` users (carol, frank, ivan, linda) **must** complete TOTP on every login
- The Authelia SQLite DB lives on a PVC (`persistence.enabled: true`) — secrets survive pod restarts
- ArgoCD SSO also uses Authelia OIDC (client_id: `argocd`, redirect: `/auth/callback`)
