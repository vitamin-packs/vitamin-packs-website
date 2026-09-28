# Cognito Authentication

This describes how the storefront and admin apps authenticate against the `cognito-auth` Terraform module (`infra/modules/cognito-auth`), and how backend Lambdas should authorize requests. Follow [Application architecture](application-architecture.md) for where frontend/backend code lives.

## What Terraform provides

- One Cognito **User Pool**, email/password login, password policy (12+ chars, upper/lower/number/symbol required), optional TOTP MFA, email-based account recovery.
- **No Hosted UI domain.** There is nothing to redirect to — every app must call Cognito directly.
- Two **app clients**, one per frontend, each with only `ALLOW_USER_SRP_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` enabled:
  - `storefront` — 60 minute access/ID tokens, 30 day refresh token.
  - `admin` — 30 minute access/ID tokens, 1 day refresh token (shorter-lived: this client grants access to a privileged panel).
- An `Admins` user group. Membership is asserted via the `cognito:groups` claim in the ID/access token — there is no separate IAM role per group.
- A Cognito **Identity Pool** and an `authenticated` IAM role exist for future direct-to-AWS needs (e.g. presigned S3 uploads from the admin panel), but the role currently has **no permissions attached**. Don't assume it grants any AWS access until a later phase attaches a scoped policy.

Read `user_pool_id`, `storefront_client_id`, `admin_client_id`, and `identity_pool_id` from the relevant environment root's Terraform outputs (`infra/dev` / `infra/prod`) — do not hardcode them. Per [Application architecture](application-architecture.md), keep these environment-specific values out of committed frontend source (inject at build time).

## Frontend integration (storefront and admin)

Both apps embed login/logout/signup/account-management UI directly — there is no redirect flow. Use `amazon-cognito-identity-js` (or the `Auth` category of `aws-amplify`, which wraps the same SRP flow) with the app's own `user_pool_id` + client ID.

### Sign up

```javascript
import { CognitoUserPool } from "amazon-cognito-identity-js";

const userPool = new CognitoUserPool({
  UserPoolId: COGNITO_USER_POOL_ID,
  ClientId: COGNITO_CLIENT_ID, // storefront or admin client ID, per app
});

function signUp(email, password) {
  return new Promise((resolve, reject) => {
    userPool.signUp(email, password, [], null, (err, result) => {
      if (err) return reject(err);
      resolve(result.user);
    });
  });
}
```

### Sign in (SRP)

```javascript
import {
  AuthenticationDetails,
  CognitoUser,
} from "amazon-cognito-identity-js";

function signIn(email, password) {
  const user = new CognitoUser({ Username: email, Pool: userPool });
  const authDetails = new AuthenticationDetails({
    Username: email,
    Password: password,
  });

  return new Promise((resolve, reject) => {
    user.authenticateUser(authDetails, {
      onSuccess: (session) => resolve(session),
      onFailure: (err) => reject(err),
      // Only relevant if MFA is enabled on the account.
      totpRequired: () => reject(new Error("MFA_REQUIRED")),
    });
  });
}
```

### Get the current session / tokens (for API calls)

```javascript
function getCurrentSession() {
  const user = userPool.getCurrentUser();
  if (!user) return Promise.resolve(null);

  return new Promise((resolve, reject) => {
    user.getSession((err, session) => {
      if (err) return reject(err);
      resolve(session.isValid() ? session : null);
    });
  });
}

async function authorizedFetch(path, options = {}) {
  const session = await getCurrentSession();
  const idToken = session?.getIdToken().getJwtToken();

  return fetch(`${apiBaseUrl}${path}`, {
    ...options,
    headers: {
      ...options.headers,
      ...(idToken ? { Authorization: `Bearer ${idToken}` } : {}),
    },
  });
}
```

Cognito's SDK automatically uses the refresh token to renew an expired session inside `getSession`, as long as the refresh token itself hasn't expired (30 days for storefront, 1 day for admin).

### Sign out

```javascript
function signOut() {
  userPool.getCurrentUser()?.signOut();
}
```

## Backend authorization

API Gateway's JWT authorizer (added in the Backend API phase) validates the token's signature and expiry against the User Pool before invoking any Lambda — Lambda code should never re-verify the JWT itself. Once validated, claims are available on the request context:

```python
def get_claims(event: dict) -> dict:
    return event["requestContext"]["authorizer"]["jwt"]["claims"]


def require_admin(event: dict) -> None:
    claims = get_claims(event)
    groups = claims.get("cognito:groups", "")
    if "Admins" not in groups.split(","):
        raise PermissionError("Admins group membership required")
```

Admin-only Lambda handlers (product/inventory/order CRUD) must call `require_admin` (or equivalent) before performing the operation — don't rely on the admin frontend simply not exposing those routes.

## MFA

MFA is optional (`mfa_configuration = "OPTIONAL"`), software-token (TOTP) only. Users who want it must associate a TOTP device via `associateSoftwareToken`/`verifySoftwareToken` in the Cognito SDK; login only requires a TOTP code for users who have completed that enrollment.
