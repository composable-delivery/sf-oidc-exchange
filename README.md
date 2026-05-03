# busbar/sf-oidc-exchange

A GitHub Action that exchanges a GitHub Actions OIDC token for a short-lived
Salesforce access token using
[RFC 8693 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693).
No stored credentials required — not in GitHub Secrets, not in Salesforce,
not anywhere.

```yaml
- uses: composable-delivery/sf-oidc-exchange@v1
  with:
    sf-token-endpoint: ${{ vars.SF_TOKEN_ENDPOINT_BASE }}
```

That's it. Your workflow can now call Salesforce APIs.

---

## Prerequisites

1. The [Busbar managed package](https://appexchange.salesforce.com) is installed
   in the target Salesforce org.
2. The `BBGitHubTokenExchangeHandler` OAuth token exchange handler is enabled
   in the org's External Client App settings.
3. A `Busbar_OIDC_Trust__mdt` CMDT row exists that authorizes this repo and
   workflow. See [Setup → Busbar in the org](#salesforce-side-setup).
4. Your workflow job has `permissions: id-token: write`.

---

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required — allows the job to request an OIDC token
      contents: read

    steps:
      - uses: actions/checkout@v4

      - uses: composable-delivery/sf-oidc-exchange@v1
        with:
          sf-token-endpoint: ${{ vars.SF_TOKEN_ENDPOINT_BASE }}

      - run: sf project deploy start --source-dir force-app
```

### With CumulusCI

```yaml
      - uses: composable-delivery/sf-oidc-exchange@v1
        with:
          sf-token-endpoint: ${{ vars.SF_TOKEN_ENDPOINT_BASE }}
          sf-alias: dev-org

      - run: cci flow run ci_feature --org dev-org
```

### Multiple orgs in one job

```yaml
      - uses: composable-delivery/sf-oidc-exchange@v1
        id: auth-qa
        with:
          sf-token-endpoint: ${{ vars.SF_QA_ENDPOINT }}
          sf-alias: qa
          set-default-org: 'false'

      - uses: composable-delivery/sf-oidc-exchange@v1
        id: auth-staging
        with:
          sf-token-endpoint: ${{ vars.SF_STAGING_ENDPOINT }}
          sf-alias: staging
          set-default-org: 'false'

      - run: sf project deploy start --target-org qa
      - run: sf project deploy start --target-org staging
```

### Without the Salesforce CLI (use the token directly)

```yaml
      - uses: composable-delivery/sf-oidc-exchange@v1
        id: auth
        with:
          sf-token-endpoint: ${{ vars.SF_TOKEN_ENDPOINT_BASE }}
          sf-login: 'false'

      - run: |
          curl -s \
            -H "Authorization: Bearer ${{ steps.auth.outputs.access-token }}" \
            "${{ steps.auth.outputs.instance-url }}/services/data/v63.0/sobjects" \
            | jq '.sobjects | length'
```

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `sf-token-endpoint` | **yes** | — | Salesforce instance URL of the target org. Example: `https://myorg.my.salesforce.com` |
| `oidc-audience` | no | `sf-token-endpoint` | Audience value embedded in the OIDC token. Defaults to the instance URL, which binds the token to one org. |
| `token-handler-apex` | no | `BBGitHubTokenExchangeHandler` | Developer name of the Apex `OauthTokenExchangeHandler` in the target org. |
| `sf-alias` | no | `busbar` | Salesforce CLI alias for the authenticated org. |
| `set-default-org` | no | `true` | Set this org as the default for subsequent `sf` commands. Set to `false` when authenticating multiple orgs. |
| `sf-login` | no | `true` | Register the token with the Salesforce CLI. Set to `false` to use `access-token` output directly. |

## Outputs

| Output | Description |
|---|---|
| `access-token` | Short-lived Salesforce access token (5-minute lifetime). Automatically masked in logs. |
| `instance-url` | Salesforce instance URL of the authenticated org. |
| `sf-alias` | Salesforce CLI alias assigned to the org. |

---

## GitHub Environment variables

Set these as **Variables** (not Secrets) in your GitHub Environment:

| Variable | Example | Description |
|---|---|---|
| `SF_TOKEN_ENDPOINT_BASE` | `https://myorg.my.salesforce.com` | Your org's My Domain URL |
| `OIDC_AUDIENCE` | *(same as above)* | Optional — only set if you need a custom audience |

These are not secrets. They identify the target org but grant no access on their own.

---

## Salesforce-side setup

### 1 — Install the Busbar managed package

Install the package from AppExchange or deploy source from
`composable-delivery/busbar-broker-sf`. The package creates the
`BBGitHubTokenExchangeHandler` Apex class, the External Client App, and the
`Busbar_OIDC_Trust__mdt` custom metadata type.

### 2 — Enable the token exchange handler

In Setup → External Client Apps → BusbarGitHubEca → OAuth Settings:
- Enable **Token Exchange Flow**
- Set **OAuth Token Handler** to `BBGitHubTokenExchangeHandler`

Or use the CI automation script:

```bash
bash scripts/ci/configure-token-exchange-handler.sh --target-org <alias>
```

### 3 — Configure trust for your repo

In Setup → Busbar → Trust Rules, create a `Busbar_OIDC_Trust__mdt` row:

| Field | Value |
|---|---|
| Repository | `your-org/your-repo` |
| Ref | `refs/heads/main` (or `*` for all refs) |
| Org Type | `Production` / `Sandbox` / `Scratch` |
| Active | ✅ |

Or navigate to **Setup → Busbar → Auth Requests** to create a trust rule
directly from a denied exchange attempt.

### 4 — Add a Remote Site Setting

Setup → Remote Site Settings → New:
- Remote Site URL: `https://token.actions.githubusercontent.com`

This allows Salesforce to fetch the GitHub JWKS for JWT signature verification.

---

## Security model

- **No stored credentials.** This action requests a fresh 5-minute GitHub OIDC
  token per run. No Salesforce credential is ever written to GitHub Secrets.
- **Two-stamp policy.** Every exchange is authorized by Cedar policy on the
  Busbar broker *and* by a CMDT row in your own org. You control both stamps.
- **Customer kill switch.** Set `Active__c = false` on the CMDT row to revoke
  access. No Busbar API call, no support ticket.
- **Salesloft-survivable.** A full Busbar broker compromise yields signing keys
  (rotatable), not your org tokens (which never existed on Busbar).

Read the full [threat model](https://busbar.agency/security).

---

## Troubleshooting

### `id-token: write` permission missing

```
Error: No OIDC token available. Add 'permissions: id-token: write' to your workflow job.
```

Add to the job that calls this action:
```yaml
permissions:
  id-token: write
  contents: read
```

### Token exchange failed: `invalid_grant`

The Apex handler rejected the exchange. Causes:
- No matching `Busbar_OIDC_Trust__mdt` row for this repo + ref + org type.
- The token exchange handler is not enabled in the External Client App.
- The `Busbar_OIDC_Trust__mdt` row exists but `Active__c = false`.

Check **Setup → Busbar → Auth Requests** in the target org — the denied request
appears there with the specific policy reason.

### `sf: command not found`

The Salesforce CLI is not installed on the runner. Either:
- Use `sf-login: 'false'` and use the `access-token` output directly, or
- Add a CLI install step before this action:
  ```yaml
  - run: npm install -g @salesforce/cli --prefer-offline
  ```

---

## License

Apache 2.0. See [LICENSE](LICENSE).
