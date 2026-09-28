# Cognito Authentication

This is the authoritative authentication and authorization contract for the storefront, the admin panel, the API Gateway HTTP API, and backend Lambdas. It describes **proposed design**: the `cognito-auth` Terraform module (`infra/modules/cognito-auth`), the authorizers, and the code below are not yet deployed or implemented. Follow [Application architecture](application-architecture.md) for where frontend/backend code lives, [Backend API](backend-api.md) for routes, and [Frontend applications](frontend-applications.md) for browser standards.

Decisions recorded 2026-09-28 (Prompt 5). Verified against the AWS documentation listed in [References](#references).

## What Terraform provides

Two Cognito **user pools**, both on the **Lite** feature plan (nothing here requires Essentials), with email as the sign-in username. No Hosted UI/managed-login domain: every app calls the Cognito user pools API directly with SRP.

| | Customer pool | Admin pool |
|---|---|---|
| Used by | Storefront (`frontend/`) | Admin panel (`admin/`) |
| Sign-up | Self-service `SignUp` with email verification | **Disabled** (`AllowAdminCreateUserOnly = true`); users created by the AWS account owner only |
| MFA | `OPTIONAL`, software token (TOTP) only | **`ON` (required)**, software token (TOTP) only |
| Account recovery | Verified email | Verified email (TOTP still required at sign-in) |
| Groups | none | `Admins` |
| App client | `storefront` | `admin` |
| Access/ID token lifetime | 30 minutes | 30 minutes |
| Refresh token lifetime | 30 days | 1 day |

Both pools share the password policy (12+ characters, upper/lower/number/symbol). Both app clients are public (no client secret) and allow only `ALLOW_USER_SRP_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH`. They have token revocation enabled (the default) and `PreventUserExistenceErrors = ENABLED`.

Admins have their own pool because MFA mode and self-sign-up are **user-pool-wide** settings. A shared pool could neither require TOTP for admins only nor stop anyone from calling `SignUp` with the admin client ID. The separate issuer also means a customer token cannot pass the admin authorizer at all.

A Cognito **Identity Pool** and `authenticated` IAM role may exist for future direct-to-AWS needs (e.g. presigned admin uploads). The role has **no permissions attached**. If it is ever used, federate the **admin** pool only and attach a scoped policy in a later phase.

Read `customer_user_pool_id`, `storefront_client_id`, `admin_user_pool_id`, `admin_client_id` (and the pools' issuer URLs) from the environment root's Terraform outputs (`infra/dev` / `infra/prod`). Do not hardcode them. Inject them at build/deploy time per [Frontend applications](frontend-applications.md).

## Token and claim contract

Browsers send the Cognito **access token** — never the ID token — as `Authorization: Bearer <accessToken>`.

| Claim | Access token (sent to the API) | ID token (never sent to the API) |
|---|---|---|
| `sub` | User's stable ID. The only identity key backend code uses. | same |
| `token_use` | `access` | `id` |
| `client_id` | App client ID | absent |
| `aud` | absent (no resource binding is used) | App client ID |
| `scope` | `aws.cognito.signin.user.admin` (the only scope API/SRP sign-in issues) | absent |
| `cognito:groups` | JSON array, e.g. `["Admins"]`; absent when the user is in no group | JSON array |
| `username` | Pool username (not the email when email is the sign-in attribute) | `cognito:username` |
| `email` | **absent** | present |
| `iss` | `https://cognito-idp.<region>.amazonaws.com/<pool_id>` | same |
| `origin_jti`, `jti`, `exp`, `iat`, `auth_time` | present | present |

### API Gateway JWT authorizers

The HTTP API has two JWT authorizers, both with identity source `$request.header.Authorization`:

| Authorizer | Issuer | Audience | Routes |
|---|---|---|---|
| `customer-jwt` | Customer pool issuer | `[storefront_client_id]` | cart, checkout, PayPal capture, orders |
| `admin-jwt` | Admin pool issuer | `[admin_client_id]` | `/admin/*` |

Every protected route sets `authorizationScopes = ["aws.cognito.signin.user.admin"]`.

- Access tokens have no `aud`, so API Gateway matches `client_id` against the audience list.
- The required scope rejects ID tokens, which have no `scope` claim. AWS notes there is no standard way to tell access tokens from ID tokens and recommends requiring scopes.
- **Status codes:** token failures (missing, malformed, bad signature, wrong issuer or `client_id`, expired) return **401**. A valid token without the required scope — including any ID token — returns **403**. HTTP APIs cannot customize authorizer responses, so the owner accepted 403 for ID tokens (2026-09-28). The frontend never sends ID tokens, so only a misconfigured client sees it.
- This scope only proves the caller holds a Cognito access token from this client. It grants **no application role**; roles are enforced in Lambda.

API Gateway checks signature, `kid`, `iss`, audience/`client_id`, `exp`, `nbf`, `iat`, and scope before invoking the Lambda. Lambda code does not re-verify the JWT signature. It still checks `token_use`, `iss`, and `client_id` against its own configuration (defense in depth against a route attached to the wrong authorizer).

**Revocation limit:** API Gateway validates tokens locally. A revoked (signed-out, disabled, or group-removed) user's already-issued access token is still accepted by the authorizer until it expires. Customer tokens are therefore usable for at most 30 minutes after revocation. Admin routes close this gap with a live Cognito check (see [Backend authorization](#backend-authorization)).

### `cognito:groups` in the Lambda event

The token carries `cognito:groups` as a JSON array. API Gateway passes JWT claims to Lambda at `event["requestContext"]["authorizer"]["jwt"]["claims"]`. AWS documents that map with string values and does **not** document how array claims are serialized; community reports show a bracketed, space-separated string such as `"[Admins Other]"`. Backend code must therefore parse the claim tolerantly and match group names exactly (see `parse_groups` below).

Group names must match `^[A-Za-z0-9_-]+$` — no spaces, commas, or brackets — so every representation parses identically. After the first dev deployment, capture one real admin-route event (token redacted) and commit it as a unit-test fixture.

## Auth sequence

1. The SPA loads build-time config: API base URL, its pool ID, and its app client ID (storefront → customer pool; admin → admin pool).
2. The app picks token storage (see [Session storage and XSS](#session-storage-and-xss)), then calls SRP `signIn`.
3. The app handles each `nextStep` challenge (TOTP code, TOTP setup, new password, confirm sign-up, reset password) until `DONE`. Cognito returns ID, access, and refresh tokens, which Amplify stores.
4. Before each protected API call, the API client calls `fetchAuthSession()`. It returns a valid access token, refreshing silently with the refresh token when needed, and sends `Authorization: Bearer <accessToken>`.
5. The API Gateway authorizer validates the token. On failure it returns 401 (invalid or expired token) or 403 (missing scope, e.g. an ID token), and the Lambda is never invoked.
6. The Lambda reads claims and then either:
   - customer routes: scopes all data to `sub`;
   - admin routes: `require_admin` checks the token claims, then does a live Cognito lookup.
7. On a 401, the client force-refreshes once and retries once. If that fails, it clears the session and shows sign-in.
8. Sign-out revokes the refresh token (admin: all of the user's tokens) and clears browser storage.

## Frontend integration (storefront and admin)

Use Amplify JS v6 `aws-amplify/auth` against the existing pools. Do not use the Amplify CLI or an Amplify backend. AWS recommends Amplify Auth in place of the older `amazon-cognito-identity-js` package. Each app configures only its own pool and client.

### Configure and choose storage

```javascript
import { Amplify } from "aws-amplify";
import { cognitoUserPoolsTokenProvider } from "aws-amplify/auth/cognito";
import { defaultStorage, sessionStorage } from "aws-amplify/utils";
import config from "./config.js";

const KEEP_SIGNED_IN_KEY = "vp.keepSignedIn"; // non-secret preference flag

Amplify.configure({
  Auth: {
    Cognito: {
      userPoolId: config.cognitoUserPoolId,
      userPoolClientId: config.cognitoClientId,
    },
  },
});

// Storefront: sessionStorage unless the customer opted in to "Keep me signed in".
// Admin: always call selectTokenStorage(false) and never offer the option.
export function selectTokenStorage(keepSignedIn) {
  try {
    if (keepSignedIn) {
      window.localStorage.setItem(KEEP_SIGNED_IN_KEY, "true");
    } else {
      window.localStorage.removeItem(KEEP_SIGNED_IN_KEY);
    }
  } catch {
    // Storage unavailable: fall through to the per-tab default.
  }
  cognitoUserPoolsTokenProvider.setKeyValueStorage(
    keepSignedIn ? defaultStorage : sessionStorage,
  );
}

// Call once at startup, before any auth call, so a returning session is found.
export function restoreTokenStorage() {
  let keepSignedIn = false;
  try {
    keepSignedIn = window.localStorage.getItem(KEEP_SIGNED_IN_KEY) === "true";
  } catch {
    keepSignedIn = false;
  }
  selectTokenStorage(keepSignedIn);
}
```

### Sign up (storefront only)

The admin app has no sign-up UI; the admin pool rejects `SignUp`.

```javascript
import { confirmSignUp, signUp } from "aws-amplify/auth";

export async function registerCustomer(email, password) {
  const { nextStep } = await signUp({
    username: email,
    password,
    options: { userAttributes: { email } },
  });
  return nextStep; // CONFIRM_SIGN_UP: prompt for the emailed code
}

export async function confirmRegistration(email, code) {
  return confirmSignUp({ username: email, confirmationCode: code });
}
```

### Sign in and challenge handling

One state machine serves both apps. Every step either completes, prompts the user, or fails with a clear error — none is silently rejected.

```javascript
import { confirmSignIn, signIn } from "aws-amplify/auth";

const APP_NAME = "Vitamin Packs"; // shown in the authenticator app

export async function startSignIn(email, password, keepSignedIn) {
  selectTokenStorage(keepSignedIn); // admin passes false
  const { nextStep } = await signIn({
    username: email,
    password,
    options: { authFlowType: "USER_SRP_AUTH" },
  });
  return describeStep(nextStep, email);
}

// Submit the user's answer to the current step (TOTP code or new password).
export async function continueSignIn(challengeResponse, email) {
  const { nextStep } = await confirmSignIn({ challengeResponse });
  return describeStep(nextStep, email);
}

function describeStep(nextStep, email) {
  switch (nextStep.signInStep) {
    case "DONE":
      return { status: "signed-in" };
    case "CONFIRM_SIGN_IN_WITH_TOTP_CODE":
      return { status: "totp-code" }; // prompt for the 6-digit code
    case "CONTINUE_SIGN_IN_WITH_TOTP_SETUP":
      // Admin pool (MFA required) on first sign-in: show the QR code and ask
      // for a code from the new authenticator.
      return {
        status: "totp-setup",
        setupUri: nextStep.totpSetupDetails.getSetupUri(APP_NAME, email).toString(),
      };
    case "CONFIRM_SIGN_IN_WITH_NEW_PASSWORD_REQUIRED":
      return { status: "new-password" }; // admin first sign-in after AdminCreateUser
    case "CONFIRM_SIGN_UP":
      return { status: "confirm-sign-up" }; // storefront: unconfirmed account
    case "RESET_PASSWORD":
      return { status: "reset-password" }; // route to the recovery flow
    default:
      throw new Error(`Unsupported sign-in step: ${nextStep.signInStep}`);
  }
}
```

Render the TOTP setup URI as a QR code and also show the secret as text for manual entry. Never log it or keep it after setup completes.

### Optional customer MFA enrollment (storefront account settings)

```javascript
import {
  setUpTOTP,
  updateMFAPreference,
  verifyTOTPSetup,
} from "aws-amplify/auth";

export async function beginTotpEnrollment(email) {
  const details = await setUpTOTP();
  return details.getSetupUri(APP_NAME, email).toString();
}

export async function finishTotpEnrollment(code) {
  await verifyTOTPSetup({ code });
  await updateMFAPreference({ totp: "PREFERRED" });
}

export async function disableTotp() {
  await updateMFAPreference({ totp: "DISABLED" });
}
```

Admins cannot disable TOTP: the admin pool requires MFA.

### Access token for API calls, refresh, and expiry

```javascript
import { fetchAuthSession } from "aws-amplify/auth";

async function currentAccessToken(forceRefresh = false) {
  const session = await fetchAuthSession({ forceRefresh });
  return session.tokens?.accessToken?.toString() ?? null;
}

export async function authorizedFetch(path, options = {}) {
  const send = async (token) =>
    fetch(`${config.apiBaseUrl}${path}`, {
      ...options,
      headers: {
        Accept: "application/json",
        ...options.headers,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    });

  let response = await send(await currentAccessToken());
  if (response.status === 401) {
    // One forced refresh and one retry; never loop.
    const refreshed = await currentAccessToken(true).catch(() => null);
    if (!refreshed) throw new SessionExpiredError();
    response = await send(refreshed);
    if (response.status === 401) throw new SessionExpiredError();
  }
  return response;
}

export class SessionExpiredError extends Error {
  constructor() {
    super("Your session has expired. Please sign in again.");
  }
}
```

`fetchAuthSession()` refreshes expired access/ID tokens automatically while the refresh token is valid (30 days storefront, 1 day admin). On `SessionExpiredError`:

1. Sign out locally and clear stored tokens.
2. Keep the intended route in in-memory app state, never in the URL together with tokens.
3. Show sign-in.

### Sign out

```javascript
import { signOut } from "aws-amplify/auth";

// Admin: always global. Storefront: global only for "Sign out of all devices".
export async function signOutUser({ global = false } = {}) {
  try {
    await signOut({ global });
  } finally {
    clearCognitoStorage();
  }
}

function clearCognitoStorage() {
  for (const store of [window.localStorage, window.sessionStorage]) {
    try {
      for (const key of Object.keys(store)) {
        if (key.startsWith("CognitoIdentityServiceProvider.")) store.removeItem(key);
      }
    } catch {
      // Storage unavailable; nothing to clear.
    }
  }
}
```

Revocation stops refresh and Cognito API use immediately. API Gateway still accepts already-issued access tokens until they expire (see [Revocation limit](#api-gateway-jwt-authorizers)).

### Password recovery

```javascript
import { confirmResetPassword, resetPassword } from "aws-amplify/auth";

export async function requestPasswordReset(email) {
  await resetPassword({ username: email });
  // Always show the same "if an account exists, we sent a code" message.
}

export async function completePasswordReset(email, code, newPassword) {
  await confirmResetPassword({ username: email, confirmationCode: code, newPassword });
}
```

With `PreventUserExistenceErrors`, responses do not reveal whether an account exists. Keep UI messages equally neutral.

## Session storage and XSS

Tokens in a static SPA are readable by any script running on the page. Storage choice limits how long a stolen token stays useful; preventing script injection is the real control.

| App | Storage | Behavior |
|---|---|---|
| Admin | `sessionStorage` only | Session ends when the tab closes; refresh token ≤ 1 day; no "remember me". |
| Storefront (default) | `sessionStorage` | Session ends when the tab closes; survives same-tab redirects to Stripe/PayPal and back. |
| Storefront ("Keep me signed in" ticked) | `localStorage` | Persists up to the 30-day refresh token lifetime. |

In-memory-only storage is lost on every reload. HttpOnly cookies need a backend-for-frontend, which the static-hosting constraint rules out. Required XSS controls (details in [Frontend applications](frontend-applications.md#session-security-and-content-security-policy)):

- A strict Content-Security-Policy on each CloudFront distribution.
- No third-party scripts in the admin app.
- `textContent`/framework escaping only.
- No tokens in URLs, logs, analytics, or error reports.
- Dependency auditing.

## Backend authorization

The backend is the only authorization boundary. The admin UI hiding a route, or the storefront omitting a button, is not access control.

Shared helpers live in `backend/shared/auth.py`:

```python
import json
import os

import boto3

ADMINS_GROUP = "Admins"
REQUIRED_TOKEN_USE = "access"

_cognito = boto3.client("cognito-idp")


class AuthServiceUnavailable(Exception):
    """Cognito could not be reached for a live authorization check (maps to 503)."""


def get_claims(event: dict) -> dict:
    try:
        return event["requestContext"]["authorizer"]["jwt"]["claims"]
    except (KeyError, TypeError) as error:
        raise PermissionError("Authenticated request required") from error


def parse_groups(raw) -> frozenset:
    """Normalize cognito:groups from any observed API Gateway representation."""
    if raw is None:
        return frozenset()
    if isinstance(raw, (list, tuple)):
        return frozenset(str(group) for group in raw if str(group))
    text = str(raw).strip()
    if not text:
        return frozenset()
    if text.startswith("[") and text.endswith("]"):
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        if isinstance(parsed, list):
            return frozenset(str(group) for group in parsed if str(group))
        return frozenset(text[1:-1].replace(",", " ").split())
    return frozenset(part.strip() for part in text.split(",") if part.strip())


def _require_access_token(claims: dict, issuer: str, client_id: str) -> None:
    if claims.get("token_use") != REQUIRED_TOKEN_USE:
        raise PermissionError("Access token required")
    if claims.get("iss") != issuer or claims.get("client_id") != client_id:
        raise PermissionError("Token was not issued for this API")
    if not claims.get("sub"):
        raise PermissionError("Token subject missing")


def require_customer_sub(event: dict) -> str:
    """Return the caller's sub; the only identity customer handlers may use."""
    claims = get_claims(event)
    _require_access_token(
        claims, os.environ["CUSTOMER_ISSUER"], os.environ["STOREFRONT_CLIENT_ID"]
    )
    return claims["sub"]


def require_admin(event: dict) -> str:
    """Authorize an Admins-group caller of the admin pool; returns their sub."""
    claims = get_claims(event)
    _require_access_token(claims, os.environ["ADMIN_ISSUER"], os.environ["ADMIN_CLIENT_ID"])
    if ADMINS_GROUP not in parse_groups(claims.get("cognito:groups")):
        raise PermissionError("Admins group membership required")

    # Live check: revocation (group removal, disable) takes effect immediately
    # even though API Gateway still accepts the unexpired token.
    pool_id = os.environ["ADMIN_USER_POOL_ID"]
    username = claims.get("username")
    if not username:
        raise PermissionError("Token username missing")
    try:
        user = _cognito.admin_get_user(UserPoolId=pool_id, Username=username)
        groups = _cognito.admin_list_groups_for_user(UserPoolId=pool_id, Username=username)
    except _cognito.exceptions.UserNotFoundException as error:
        raise PermissionError("Admin account not found") from error
    except Exception as error:  # botocore ClientError, throttling, network
        raise AuthServiceUnavailable("Authorization service unavailable") from error

    if not user.get("Enabled") or user.get("UserStatus") != "CONFIRMED":
        raise PermissionError("Admin account is not active")
    live_groups = {group["GroupName"] for group in groups.get("Groups", [])}
    if ADMINS_GROUP not in live_groups:
        raise PermissionError("Admins group membership required")
    return claims["sub"]
```

Rules:

- **Admin handlers** call `require_admin(event)` before any other work. The admin function's role gets only `cognito-idp:AdminGetUser` and `cognito-idp:AdminListGroupsForUser` on the admin pool ARN (see [Backend API](backend-api.md#iam)). The live check adds two small Cognito calls per admin request; acceptable at single-staff-user volume. Never cache the result across requests.
- **Customer handlers** call `require_customer_sub(event)` and derive every key from that `sub` (`CART#<sub>`, `USER#<sub>`, `GSI2PK=USER#<sub>`). Never accept a user ID from the path, query string, or body.
- **Ownership:** order-scoped reads and actions (`GET /orders/{orderId}`, `POST /checkout/paypal/capture`) load the order header and return **404** when it is missing or its `user_sub` differs from the caller's `sub`. This avoids confirming that another customer's order exists.
- **Email:** access tokens carry no email. Handlers that need it read the customer's stored profile or call Cognito server-side; never trust an email from the request body for authorization.
- **Fail closed:** a missing claim or unexpected format is a 403. Cognito being unreachable during an admin check is a 503, never an allow.
- Log `sub`, route, and allow/deny decision. Never log tokens, the `Authorization` header, or full claim sets.

## Failure behavior

| Situation | Who responds | Result | Client behavior |
|---|---|---|---|
| No/malformed token, bad signature, wrong issuer or `client_id`, expired token | API Gateway authorizer | 401 | Force-refresh once, retry once, then sign-in screen |
| ID token sent (no `scope`), or scope missing | API Gateway authorizer | 403 | Client bug (the apps never send ID tokens); show "not authorized" |
| Customer token on `/admin/*`, admin token on customer routes | API Gateway authorizer (issuer/audience mismatch) | 401 | Sign-in screen for that app |
| Wrong `token_use`/`iss`/`client_id` reaching Lambda (misattached route) | Lambda | 403 | Show "not authorized" |
| Not in `Admins` (claim or live check), disabled or unconfirmed admin | Lambda `require_admin` | 403 | Admin app shows "not authorized" with a sign-out button |
| Cognito unavailable during admin live check | Lambda | 503 | Show retryable error; do not sign out |
| Customer requests another customer's order or capture | Lambda ownership check | 404 | Show "order not found" |
| Refresh token expired or revoked | Amplify `fetchAuthSession` | error | Clear storage, sign-in screen |
| Wrong TOTP code (5+ failures trigger Cognito lockout backoff) | Cognito | error | Show neutral error; allow retry |

## Admin onboarding, audit, revocation, and recovery

The **AWS account owner**, using an IAM principal with MFA, is the only operator. Do not create Cognito users with Terraform: `aws_cognito_user` would place temporary passwords in state. There is no standing break-glass admin user. Recovery is re-provisioning by the account owner.

**Onboard** (targeting the environment's admin pool explicitly):

```sh
aws cognito-idp admin-create-user --user-pool-id "$ADMIN_POOL_ID" \
  --username "$ADMIN_EMAIL" --user-attributes Name=email,Value="$ADMIN_EMAIL" Name=email_verified,Value=true \
  --desired-delivery-mediums EMAIL
aws cognito-idp admin-add-user-to-group --user-pool-id "$ADMIN_POOL_ID" \
  --username "$ADMIN_EMAIL" --group-name Admins
```

On first sign-in the admin completes `CONFIRM_SIGN_IN_WITH_NEW_PASSWORD_REQUIRED`, then `CONTINUE_SIGN_IN_WITH_TOTP_SETUP`, then a TOTP code.

**Audit:** CloudTrail records every user-pool API action as a management event:

- `AdminCreateUser`
- `AdminAddUserToGroup`
- `AdminRemoveUserFromGroup`
- `AdminUserGlobalSignOut`
- `AdminDisableUser`
- `AdminDeleteUser`

Events identify the user by `sub`, not username. CloudTrail Event history's 90-day retention is sufficient (owner decision, 2026-09-28); no dedicated trail is required. The admin Lambda additionally logs `sub` and decision per request.

**Revoke** (takes effect on the admin's next API request because of the live check):

```sh
aws cognito-idp admin-remove-user-from-group --user-pool-id "$ADMIN_POOL_ID" --username "$ADMIN_EMAIL" --group-name Admins
aws cognito-idp admin-user-global-sign-out --user-pool-id "$ADMIN_POOL_ID" --username "$ADMIN_EMAIL"
aws cognito-idp admin-disable-user --user-pool-id "$ADMIN_POOL_ID" --username "$ADMIN_EMAIL"
```

**Recover:**

- **Forgotten password:** self-service email reset. TOTP is still required at the next sign-in, so email access alone is not enough.
- **Lost TOTP device:**
  1. The account owner verifies the person out of band.
  2. Create a **new** admin user (onboard steps) and revoke and disable the old one. MFA is required in this pool, so the factor cannot simply be turned off.
  3. Any admin-authored records reference the old `sub`; note the mapping in the change record.

## Acceptance tests

Run in dev against the deployed API with raw HTTP requests (no UI):

- Public catalog routes succeed with no token.
- Every protected route returns **401** for no token, an expired token, a token from the other pool, and a token with the wrong `client_id`, and **403** for an ID token.
- Every `/admin/*` route rejects a valid storefront access token and a valid admin-pool token for a user not in `Admins`.
- An admin succeeds. After `admin-remove-user-from-group`, the **next** admin request returns 403 without waiting for token expiry.
- Customer A cannot read customer B's order or capture B's PayPal order (404). A's `PUT /cart` only affects `CART#<sub_A>`.
- Admin pool rejects `SignUp` via the admin client ID. Admin sign-in without TOTP set up forces TOTP setup.
- A customer with TOTP enrolled is prompted for a code; one without is not.
- Sign-out clears browser storage. Global sign-out prevents refresh.
- `parse_groups` unit tests cover: a list; a JSON array string; `"[Admins Other]"`; `"Admins,Other"`; empty/`None`/`"[]"`; and near-misses `"NotAdmins"` and `"Admins2"`. The captured real event fixture must also pass.

## References

- API Gateway HTTP API JWT authorizers: https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-jwt-authorizer.html
- HTTP API JWT authorizer 401 responses (`www-authenticate`): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-troubleshooting-jwt.html
- HTTP API vs REST API (no custom gateway responses for HTTP APIs): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html
- HTTP API Lambda payload format (claims location): https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html
- Cognito access token claims: https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html
- Cognito ID token claims: https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-id-token.html
- Token revocation and its limits: https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html
- User pool MFA (pool-wide modes, `MFA_SETUP`): https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-settings-mfa.html
- Sign-up, confirmation, admin-created users: https://docs.aws.amazon.com/cognito/latest/developerguide/signing-up-users-in-your-app.html
- CloudTrail logging for Cognito: https://docs.aws.amazon.com/cognito/latest/developerguide/logging-using-cloudtrail.html
- Amplify v6 token storage: https://docs.amplify.aws/javascript/build-a-backend/auth/concepts/tokens-and-credentials/
- Amplify v6 sign-in steps: https://docs.amplify.aws/javascript/build-a-backend/auth/connect-your-frontend/sign-in/
- `amazon-cognito-identity-js` → Amplify guidance: https://repost.aws/questions/QUWQXaGAzPTXy95oH8DupLJg
