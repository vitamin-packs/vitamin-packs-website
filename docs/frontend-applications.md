# Frontend Applications

This guide applies to both static web applications:

- `frontend/` contains the customer-facing storefront.
- `admin/` contains the administration panel.

Both applications use HTML, modern JavaScript, and Node.js tooling. Their build output must be deployable as static files to separate private S3 buckets and served through their CloudFront distributions. Follow [Application architecture](application-architecture.md) for the AWS integration boundaries and [Cognito authentication](cognito-authentication.md) for embedded authentication.

## Application boundaries

Keep the applications independently buildable and deployable:

```text
frontend/                 # storefront
  package.json
  index.html
  src/
  public/

admin/                    # admin panel
  package.json
  index.html
  src/
  public/
```

Do not import source modules across the two applications. If code becomes genuinely shared, extract a separately versioned package or duplicate only a small, stable utility with an explicit reason. The storefront must never contain admin-only operations or credentials. The admin application must still rely on backend authorization; hiding a route in the browser is not security.

## Static hosting constraints

- Build to static HTML, CSS, JavaScript, and asset files. Do not require a Node.js server at runtime.
- Use relative or correctly configured absolute asset paths that work when uploaded to S3 and delivered through CloudFront.
- Treat the CloudFront distribution as the public origin. Do not add direct public access to the S3 buckets.
- Support client-side routing through the existing CloudFront SPA fallback to `/index.html`.
- Inject environment-specific, non-secret configuration at build time (for example, API endpoint, Cognito User Pool ID, and app client ID). Do not commit environment-specific values when they belong in deployment configuration.
- Never put Stripe secret keys, PayPal client secrets, AWS credentials, or other private values in browser code. Payment initiation and provider secrets stay in Python Lambda.
- Use the API Gateway endpoint for backend requests. Never invoke Lambda directly from the browser.

A minimal build configuration should expose only public runtime settings:

```javascript
const config = {
  apiBaseUrl: import.meta.env.VITE_API_BASE_URL,
  cognitoUserPoolId: import.meta.env.VITE_COGNITO_USER_POOL_ID,
  cognitoClientId: import.meta.env.VITE_COGNITO_CLIENT_ID,
};

for (const [name, value] of Object.entries(config)) {
  if (!value) {
    throw new Error(`Missing frontend configuration: ${name}`);
  }
}

export default config;
```

Values exposed to a browser are public by definition. Cognito app client IDs and User Pool IDs are identifiers, not secrets; do not confuse them with credentials or signing keys.

## HTML standards

Every document must:

- Declare `<!doctype html>` and a valid language on the root `<html lang="en">` element.
- Include a UTF-8 charset and a responsive viewport.
- Have one meaningful page title that changes with the current view where appropriate.
- Use semantic landmarks (`header`, `nav`, `main`, `aside`, `footer`) and headings in a logical order.
- Use buttons for actions and links for navigation. Do not use clickable `div` or `span` elements as controls.
- Associate every form control with a visible or programmatic label.
- Provide useful alternative text for informative images; use empty alt text only for genuinely decorative images.
- Keep IDs unique and ensure labels, descriptions, and error messages reference the correct control.
- Avoid invalid nesting, duplicate attributes, missing required attributes, and obsolete HTML elements.

For dynamic states, expose the state semantically: use `aria-live` for important asynchronous status messages, `aria-busy` for loading regions, and `aria-expanded`/`aria-controls` for expandable controls. Do not add ARIA where native HTML already provides the correct behavior.

## Modern JavaScript standards

- Use ES modules and `const`/`let`; do not use `var`.
- Prefer `async`/`await` with explicit error handling for asynchronous work.
- Keep browser-side state immutable where practical and avoid mutating API response objects.
- Validate untrusted API responses before rendering them.
- Use `textContent` or framework escaping for user-controlled text. Do not pass untrusted strings to `innerHTML`, `dangerouslySetInnerHTML`, or dynamic script creation.
- Keep network calls in a small API client layer so authentication headers, JSON parsing, error handling, and abort behavior are consistent.
- Abort stale requests where a view can unmount or a newer search supersedes an older one.
- Handle loading, empty, success, and error states for every API-backed view.
- Do not log passwords, access tokens, payment details, or full customer records.
- Keep functions focused and names descriptive; do not use one-letter variables except for conventional callback arguments where the meaning is unambiguous.

Example API helper:

```javascript
export async function request(path, options = {}, signal) {
  const response = await fetch(`${config.apiBaseUrl}${path}`, {
    ...options,
    signal,
    headers: {
      Accept: "application/json",
      ...options.headers,
    },
  });

  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(payload?.message || "The request could not be completed.");
  }
  return payload;
}
```

## Required feature boundaries

### Storefront

The storefront owns public catalog browsing, product details, kit bills of materials, external links for non-stocked parts, cart operations, checkout initiation, and customer order history. It embeds Cognito sign-up, login, logout, password reset, MFA, and account-management UI directly in the application.

Kit-only components must not be presented as standalone products. The API is authoritative and omits them from catalog results; the UI should also treat `sellable_individually: false` items as BOM components rather than purchasable catalog products.

### Admin panel

The admin panel owns product/inventory/order management and embeds its own Cognito account UI using the admin app client. It must:

- Require a valid Cognito session before rendering protected views.
- Check the authenticated user's Admins-group claim for UI navigation, while relying on backend enforcement for actual authorization.
- Never expose admin API responses or controls to logged-out users.
- Confirm destructive product or inventory operations before submitting them.
- Display server-side validation and authorization failures without exposing stack traces or secret data.

## Validation and checks

Each application must have Node.js scripts for at least:

```text
npm run build       # production static build
npm run lint        # modern JavaScript linting
npm run test        # unit/component tests
npm run validate:html  # HTML validation, if a standalone HTML validator is used
```

Use a modern ESLint configuration for JavaScript and JSX. Enable rules that catch unused variables/imports, accidental globals, unreachable code, unsafe non-null assumptions, and accessibility issues in JSX. Use an HTML validator for authored HTML and test the generated build output for required document metadata and broken asset references.

Before deployment, run the checks in both `frontend` and `admin`, inspect the generated output, and confirm:

- The build succeeds without warnings that indicate missing assets or invalid configuration.
- No secrets or private credentials appear in the generated files.
- Keyboard navigation, focus visibility, form errors, responsive layouts, and reduced-motion behavior work at mobile and desktop widths.
- Authenticated API calls include the current Cognito token and recover cleanly from expired sessions.
- Public storefront routes do not accidentally require authentication, while cart/order/admin routes do.
- The admin bundle and admin API paths are not imported into the storefront bundle.
