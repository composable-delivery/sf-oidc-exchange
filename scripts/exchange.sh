#!/usr/bin/env bash
# exchange.sh — RFC 8693 token exchange: GitHub OIDC → Salesforce access token.
# Called by action.yml. All configuration arrives via environment variables.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fail() {
  echo "::error::busbar/exchange-action: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1. Ensure it is available on the runner."
}

emit_output() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
}

mask_value() {
  # Instruct the runner to redact a value from all subsequent log lines.
  if [ -n "${GITHUB_OUTPUT:-}" ] && [ -n "$1" ]; then
    echo "::add-mask::$1"
  fi
}

assert_json() {
  local payload="$1" context="$2"
  echo "$payload" | jq -e . >/dev/null 2>&1 \
    || fail "$context returned a non-JSON response. Raw: $(echo "$payload" | head -c 500)"
}

decode_base64() {
  local v="$1"
  printf '%s' "$v" | base64 --decode 2>/dev/null \
    || printf '%s' "$v" | base64 -d 2>/dev/null \
    || printf '%s' "$v" | base64 -D 2>/dev/null \
    || return 1
}

decode_jwt_payload() {
  local token="$1"
  local seg="${token#*.}"; seg="${seg%%.*}"
  [ -n "$seg" ] && [ "$seg" != "$token" ] || fail "OIDC token does not contain a JWT payload segment."

  # Restore standard base64 from base64url, then pad.
  local b64="${seg//-/+}"; b64="${b64//_/\/}"
  local rem=$(( ${#b64} % 4 ))
  [ "$rem" -eq 2 ] && b64="${b64}=="
  [ "$rem" -eq 3 ] && b64="${b64}="
  [ "$rem" -ne 0 ] && [ "$rem" -ne 2 ] && [ "$rem" -ne 3 ] && fail "OIDC token payload is not valid base64url."

  local decoded
  decoded="$(decode_base64 "$b64")" || fail "Unable to decode OIDC token payload."
  assert_json "$decoded" "Decoded JWT payload"
  printf '%s' "$decoded"
}

is_sha1_hex() { [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]; }

audience_present() {
  local payload="$1" expected="$2"
  echo "$payload" | jq -e --arg e "$expected" '
    if .aud == null then false
    elif (.aud | type) == "array" then (.aud | index($e)) != null
    else (.aud | tostring) == $e
    end
  ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

require_command jq
require_command curl

SF_TOKEN_ENDPOINT_BASE="${SF_TOKEN_ENDPOINT_BASE:-}"
[ -n "$SF_TOKEN_ENDPOINT_BASE" ] \
  || fail "sf-token-endpoint is required. Set it to the Salesforce instance URL, e.g. https://myorg.my.salesforce.com"

TOKEN_HANDLER_APEX="${TOKEN_HANDLER_APEX:-BBGitHubTokenExchangeHandler}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-$SF_TOKEN_ENDPOINT_BASE}"
TARGET_ALIAS="${TARGET_ALIAS:-busbar}"
SET_DEFAULT_ORG="${SET_DEFAULT_ORG:-true}"
SF_LOGIN="${SF_LOGIN:-true}"
EXPECTED_ISSUER="https://token.actions.githubusercontent.com"
SUBJECT_TOKEN_TYPE="urn:ietf:params:oauth:token-type:jwt"

# ECA_CLIENT_ID is the public ISV consumer key for the BusbarGitHubEca
# External Client App. It is NOT a secret — it is the same value in every
# subscriber org by design and is safe to commit. See CLAUDE.md for the
# rotation runbook.
ECA_CLIENT_ID="${ECA_CLIENT_ID:-3MVG9bYGb9rFSjxQioAj.K3MUhq4_MgJrgRZ3dtYZsCqFX4TFw18.tt9XpMSwBISSwBK84dw1G_X.ESlzE2ZC}"

# ---------------------------------------------------------------------------
# Step 1: Request GitHub OIDC token
# ---------------------------------------------------------------------------

echo "::group::Request GitHub OIDC token"

GITHUB_ID_TOKEN_VALUE="${GITHUB_ID_TOKEN:-}"

if [ -z "$GITHUB_ID_TOKEN_VALUE" ]; then
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] \
    || fail "No OIDC token available. Add 'permissions: id-token: write' to your workflow job."

  AUDIENCE_ENCODED="$(printf '%s' "$OIDC_AUDIENCE" | jq -sRr @uri)"
  OIDC_URL="$ACTIONS_ID_TOKEN_REQUEST_URL"
  [[ "$OIDC_URL" == *"?"* ]] && OIDC_URL="${OIDC_URL}&audience=${AUDIENCE_ENCODED}" \
                              || OIDC_URL="${OIDC_URL}?audience=${AUDIENCE_ENCODED}"

  OIDC_RESPONSE="$(
    curl --silent --show-error --fail-with-body \
      -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "$OIDC_URL"
  )"
  assert_json "$OIDC_RESPONSE" "GitHub OIDC token request"

  OIDC_ERROR="$(echo "$OIDC_RESPONSE" | jq -r '.error // empty')"
  if [ -n "$OIDC_ERROR" ]; then
    OIDC_DESC="$(echo "$OIDC_RESPONSE" | jq -r '.error_description // .error')"
    fail "GitHub OIDC token request failed: $OIDC_DESC"
  fi

  GITHUB_ID_TOKEN_VALUE="$(echo "$OIDC_RESPONSE" | jq -r '.value // empty')"
fi

[ -n "$GITHUB_ID_TOKEN_VALUE" ] || fail "Unable to resolve a GitHub OIDC token value."

echo "::endgroup::"

# ---------------------------------------------------------------------------
# Step 2: Validate JWT claims (preflight — fail fast before the SF callout)
# ---------------------------------------------------------------------------

echo "::group::Validate OIDC token claims"

JWT_PAYLOAD="$(decode_jwt_payload "$GITHUB_ID_TOKEN_VALUE")"
JWT_ISSUER="$(echo "$JWT_PAYLOAD"       | jq -r '.iss // empty')"
JWT_REPOSITORY="$(echo "$JWT_PAYLOAD"   | jq -r '.repository // empty')"
JWT_REF="$(echo "$JWT_PAYLOAD"          | jq -r '.ref // empty')"
JWT_JWF_REF="$(echo "$JWT_PAYLOAD"      | jq -r '.job_workflow_ref // empty')"
JWT_JWF_SHA="$(echo "$JWT_PAYLOAD"      | jq -r '.job_workflow_sha // empty')"
JWT_WF_SHA="$(echo "$JWT_PAYLOAD"       | jq -r '.workflow_sha // empty')"

[ -n "$JWT_ISSUER" ]     || fail "OIDC token missing required 'iss' claim."
[ "$JWT_ISSUER" = "$EXPECTED_ISSUER" ] \
  || fail "Unsupported issuer '$JWT_ISSUER'. Expected '$EXPECTED_ISSUER'."

[[ "$JWT_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "OIDC 'repository' claim must use owner/repo format. Got: '$JWT_REPOSITORY'."

[ -n "$JWT_JWF_REF" ] \
  || fail "OIDC token missing required 'job_workflow_ref' claim."

{ [ -n "$JWT_JWF_SHA" ] || [ -n "$JWT_WF_SHA" ]; } \
  || fail "OIDC token missing required workflow SHA claim ('job_workflow_sha' or 'workflow_sha')."

{ [ -z "$JWT_JWF_SHA" ] || is_sha1_hex "$JWT_JWF_SHA"; } \
  || fail "OIDC 'job_workflow_sha' must be a 40-char hex SHA. Got: '$JWT_JWF_SHA'."

{ [ -z "$JWT_WF_SHA" ] || is_sha1_hex "$JWT_WF_SHA"; } \
  || fail "OIDC 'workflow_sha' must be a 40-char hex SHA. Got: '$JWT_WF_SHA'."

audience_present "$JWT_PAYLOAD" "$OIDC_AUDIENCE" \
  || fail "OIDC audience mismatch. Expected '$OIDC_AUDIENCE' to be present in token aud claim."

echo "Preflight passed: issuer='$JWT_ISSUER' repository='$JWT_REPOSITORY' ref='${JWT_REF:-<unset>}' job_workflow_ref='$JWT_JWF_REF'"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Step 3: RFC 8693 token exchange
# ---------------------------------------------------------------------------

echo "::group::Token exchange with Salesforce"

TOKEN_ENDPOINT="${SF_TOKEN_ENDPOINT_BASE%/}/services/oauth2/token"

TOKEN_RESPONSE="$(
  curl --silent --show-error \
    -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "client_id=${ECA_CLIENT_ID}" \
    --data-urlencode "subject_token_type=${SUBJECT_TOKEN_TYPE}" \
    --data-urlencode "subject_token=${GITHUB_ID_TOKEN_VALUE}" \
    --data-urlencode "token_handler=${TOKEN_HANDLER_APEX}"
)"

assert_json "$TOKEN_RESPONSE" "Salesforce token exchange"

ACCESS_TOKEN="$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"
INSTANCE_URL="$(echo "$TOKEN_RESPONSE" | jq -r '.instance_url // empty')"

if [ -z "$ACCESS_TOKEN" ] || [ -z "$INSTANCE_URL" ]; then
  ERROR_MSG="$(echo "$TOKEN_RESPONSE" | jq -r '.error_description // .error // "Unknown token exchange failure."')"
  fail "Token exchange failed: $ERROR_MSG"
fi

# Mask the access token so it never appears in logs.
mask_value "$ACCESS_TOKEN"

echo "Token exchange succeeded: instance_url='$INSTANCE_URL'"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# Step 4: Register with Salesforce CLI (optional)
# ---------------------------------------------------------------------------

if [ "$SF_LOGIN" = "true" ]; then
  echo "::group::Register org with Salesforce CLI"

  require_command sf

  SET_DEFAULT_FLAG=""
  [ "$SET_DEFAULT_ORG" = "true" ] && SET_DEFAULT_FLAG="--set-default"

  SF_ACCESS_TOKEN="$ACCESS_TOKEN" sf org login access-token \
    --instance-url "$INSTANCE_URL" \
    --alias "$TARGET_ALIAS" \
    --no-prompt \
    $SET_DEFAULT_FLAG

  echo "Org registered with Salesforce CLI as alias '$TARGET_ALIAS'."
  echo "::endgroup::"
fi

# ---------------------------------------------------------------------------
# Step 5: Emit outputs
# ---------------------------------------------------------------------------

emit_output "access_token" "$ACCESS_TOKEN"
emit_output "instance_url" "$INSTANCE_URL"
emit_output "sf_alias"     "$TARGET_ALIAS"

echo "busbar/exchange-action: authentication complete. instance_url='$INSTANCE_URL' alias='$TARGET_ALIAS'"
