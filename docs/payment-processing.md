# Payment Processing (Stripe + PayPal)

This describes how checkout and payment confirmation work across both supported providers. Follow [Application architecture](application-architecture.md) for where backend code lives and [DynamoDB data model](dynamodb-data-model.md) for the order schema referenced below.

## Overview

The customer picks Stripe or PayPal at checkout. Both providers follow the same shape from the backend's point of view:

1. A `checkout` Lambda creates a provider-side payment session/order from the cart and returns whatever the frontend needs to redirect to or render the provider's payment UI.
2. The customer completes payment with the provider.
3. A provider-specific webhook Lambda (`webhooks-stripe`, `webhooks-paypal`) receives an asynchronous confirmation, verifies it came from the provider, and is the **only** place that transitions an order to `paid`. Never mark an order paid directly from the checkout Lambda or a frontend callback — those can be skipped, retried, or spoofed.

## Secrets

Store each provider's API key and webhook signing secret in AWS Secrets Manager, one secret per provider per environment (e.g. `${project}/${environment}/stripe`, `${project}/${environment}/paypal`). Never commit keys or hardcode them in Lambda source, per [Application architecture](application-architecture.md). Grant each Lambda's execution role read access to only the secret(s) it needs.

The `payments` Terraform module creates these secret containers but never creates a secret version. Populate them after applying the environment stack with JSON matching the provider:

Stripe secret `${project}/${environment}/stripe`:

```json
{"api_key":"sk_test_...","webhook_secret":"whsec_..."}
```

PayPal secret `${project}/${environment}/paypal`:

```json
{"client_id":"...","client_secret":"...","webhook_id":"..."}
```

Use the provider's sandbox credentials in dev and live credentials in prod. The current Lambda implementation uses the PayPal Orders API production endpoint; switch the endpoint to sandbox as an environment-specific setting before testing dev payments.

## Order status

Order header items (see [DynamoDB data model](dynamodb-data-model.md)) carry a `status` attribute with these values:

```
pending      # created at checkout, payment not yet confirmed
paid         # webhook confirmed payment
fulfilled    # kit(s) shipped (SHIP movement completed)
cancelled    # checkout abandoned, payment failed, or hold expired
refunded
```

They also carry a separate `inventory_state`, because payment state and inventory state are independent:

```
reserved | released | commit_pending | committed | ship_pending | shipped | uncommit_pending | restocked | needs_attention
```

Only a webhook handler may move an order from `pending` to `paid`. Use a conditional update (`ConditionExpression="attribute_exists(PK) AND #status = :pending"`) so a duplicate or out-of-order webhook delivery can't re-apply the transition. The one exception is a late payment on an order whose hold was released (`cancelled` with `release_reason = expired`). It is handled by the separate late-payment row below, never by the normal transition.

## Order, Payment and Inventory States

Reservation states are `HELD`, `COMMITTING`, `COMMITTED`, `RETIRED`, and `RELEASED`. Job states are `QUEUED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`, `CANCELLED`, and `NEEDS_ATTENTION`. Keys, conditions, and pseudocode are in [DynamoDB data model](dynamodb-data-model.md#inventory-projection-and-reservations). Movement mechanics are in [InvenTree integration](inventree-integration.md#physical-movements).

In the table, `q` is the part quantity the order reserved, and `obs`, `res`, and `avail` are the projection's `observed_qty`, `reserved_qty`, and `available_qty`.

| # | Event | Guard | Order `status` / `inventory_state` | Reservation | Job / InvenTree | Projection |
|---|---|---|---|---|---|---|
| 1 | Checkout succeeds | the transaction's conditions (fresh, `avail ≥ q`, price, mapping, cart version) | — → `pending` / `reserved` | — → `HELD` | none | `res += q`, `avail -= q` |
| 2 | Checkout rejected (insufficient, stale, missing, `ERROR`, changed cart) | transaction cancelled | no order written | none | none | none |
| 3 | Provider session creation fails | reservation `HELD` | `pending` → `cancelled` / `released` | `HELD` → `RELEASED` (`session_failed`) | none | `res -= q`, `avail += q` |
| 4 | Customer cancels, or a verified payment-failed event arrives | `HELD`, order `pending` | → `cancelled` / `released` | → `RELEASED` | none | release |
| 5 | Hold expires (sweeper) | `HELD`, `expires_at < now`, provider session made unpayable first | → `cancelled` / `released` | → `RELEASED` (`expired`) | none | release |
| 6 | Verified payment | order `pending`, reservation `HELD` | → `paid` / `commit_pending` | → `COMMITTING` | COMMIT `QUEUED` and message sent | none (still reserved) |
| 7 | Verified payment after release (late) | order `cancelled`, reason `expired` | → `paid`, then re-reserve: success → `commit_pending` (row 6); failure → `needs_attention` | new `HELD`, then `COMMITTING`, or none | COMMIT or operator | re-reserve, or none |
| 8 | COMMIT succeeds | job `IN_PROGRESS` with a matching lease; tracking evidence present | `paid` / `committed` | → `COMMITTED` | job → `COMPLETED`; transfer to the committed location | `pending_retire` entry added |
| 9 | Sync observes the commit | entry `completed_at` before the snapshot started | unchanged | → `RETIRED` | none | `obs -= q`, `res -= q`, `avail` unchanged |
| 10 | COMMIT fails permanently (shortfall, mapping error, mismatch) | retries exhausted or a discrepancy | `paid` / `needs_attention`; fulfillment blocked | stays `COMMITTING` (still counted) | `NEEDS_ATTENTION`; alert | none until the operator retries or cancels |
| 11 | Refund or cancel after payment, COMMIT not started | job `QUEUED` | → `refunded` / `released` | `COMMITTING` → `RELEASED` (`refunded_before_commit`) | job → `CANCELLED` (same transaction) | release |
| 12 | Refund or cancel after payment, COMMIT in progress | job `IN_PROGRESS` | wait for row 8 or 10, then row 13 | — | — | — |
| 13 | Refund or cancel after commit, not shipped | `committed` | → `refunded` / `uncommit_pending`, then `restocked` | unchanged (`COMMITTED` or `RETIRED`) | UNCOMMIT: transfer back | `obs` rises on the next sync |
| 14 | Admin ships | `inventory_state = committed` | → `ship_pending`, then `fulfilled` / `shipped` | unchanged | SHIP: remove from the committed location | none |
| 15 | Refund or chargeback after shipping | `shipped` | → `refunded` / `shipped` | unchanged | none (no restock) | none |
| 16 | Return received | staff record it in InvenTree | unchanged; the admin notes the return | unchanged | staff put it in `Returns – inspection`, status RETURNED | none until staff move it to an eligible location with status OK |

Every row is one conditional DynamoDB transaction, or a sequence of them in which each step is independently retryable and guarded by the prior state. There is no cross-system atomicity. InvenTree effects happen only inside jobs, and a payment webhook never proves that stock changed.

## Idempotency

Both providers retry webhook delivery, so handlers must be idempotent. Before processing, write a marker item with a conditional put so a retried event is a no-op:

```python
def already_processed(provider: str, event_id: str) -> bool:
    try:
        table.put_item(
            Item={"PK": f"WEBHOOK#{provider}#{event_id}", "SK": "RECEIVED"},
            ConditionExpression="attribute_not_exists(PK)",
        )
        return False
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return True
        raise
```

## Stripe

The current implementation uses Python's standard library HTTP client to avoid adding a dependency to the Lambda package. Create a Checkout Session server-side; the frontend redirects to the returned `url`.

The checkout handler posts a form-encoded request to Stripe's `/v1/checkout/sessions` endpoint with `client_reference_id` set to the internal order ID. The response's `url` is returned to the frontend. The amount is calculated from the server-side product records, never from a client-supplied price.

Verify webhook signatures using the `Stripe-Signature` header and the webhook signing secret — reject anything that doesn't verify:

```python
def handle_stripe_webhook(event: dict, context) -> dict:
    payload = event["body"]
    sig_header = event["headers"].get("stripe-signature", "")
    webhook_secret = get_secret("stripe")["webhook_secret"]

    try:
        stripe_event = stripe.Webhook.construct_event(payload, sig_header, webhook_secret)
    except (ValueError, stripe.error.SignatureVerificationError):
        return {"statusCode": 400, "body": "invalid signature"}

    if already_processed("stripe", stripe_event["id"]):
        return {"statusCode": 200, "body": "already processed"}

    if stripe_event["type"] == "checkout.session.completed":
        order_id = stripe_event["data"]["object"]["client_reference_id"]
        mark_order_paid(order_id, provider="stripe", payment_ref=stripe_event["data"]["object"]["payment_intent"])

    return {"statusCode": 200, "body": "ok"}
```

## PayPal

The checkout handler uses Python's standard library HTTP client with PayPal Orders v2 REST API. It creates an order server-side with the storefront's success/cancel URLs as PayPal application context; the frontend redirects to the returned approval link, then calls the authenticated `POST /checkout/paypal/capture` route with PayPal's returned `token` after approval.

```python
def create_paypal_order(order_id: str, amount: str, currency: str) -> dict:
    credentials = get_secret("paypal")
    access_token = get_paypal_access_token(credentials)

    response = requests.post(
        f"{PAYPAL_API_BASE}/v2/checkout/orders",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "intent": "CAPTURE",
            "purchase_units": [{"reference_id": order_id, "amount": {"currency_code": currency, "value": amount}}],
        },
        timeout=10,
    )
    response.raise_for_status()
    return response.json()
```

Verify webhook signatures using PayPal's `/v1/notifications/verify-webhook-signature` endpoint (do not trust the payload without this check):

```python
def verify_paypal_webhook(headers: dict, body: str, webhook_id: str, access_token: str) -> bool:
    response = requests.post(
        f"{PAYPAL_API_BASE}/v1/notifications/verify-webhook-signature",
        headers={"Authorization": f"Bearer {access_token}"},
        json={
            "auth_algo": headers["paypal-auth-algo"],
            "cert_url": headers["paypal-cert-url"],
            "transmission_id": headers["paypal-transmission-id"],
            "transmission_sig": headers["paypal-transmission-sig"],
            "transmission_time": headers["paypal-transmission-time"],
            "webhook_id": webhook_id,
            "webhook_event": json.loads(body),
        },
        timeout=10,
    )
    response.raise_for_status()
    return response.json().get("verification_status") == "SUCCESS"
```

On a verified `PAYMENT.CAPTURE.COMPLETED` (or `CHECKOUT.ORDER.APPROVED`, depending on which step you capture on) event, mark the order paid the same way as the Stripe path, keyed by the PayPal order/capture ID as `payment_ref`.

## Inventory

Reserve inventory in the checkout transaction ([Checkout reservation](dynamodb-data-model.md#checkout-reservation-pseudocode)) when the order is placed, not when payment is confirmed. Otherwise two customers could check out with the last unit before either pays. Everything after that follows the [state table](#order-payment-and-inventory-states).

**Hold duration.** Create the Stripe Checkout Session with `expires_at` = now + 30 minutes. Stripe accepts 30 minutes to 24 hours and defaults to 24 hours ([Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create)). The reservation's `expires_at` is now + 35 minutes. PayPal uses the same 35-minute hold. Prompt 4 confirms PayPal's order-approval lifetime.

**Expiry never races a payment.** An expiry sweeper runs every 5 minutes. For each candidate `INVHOLD` reservation it first makes the provider session unpayable, and releases only after that:

- **Stripe:** call `POST /v1/checkout/sessions/{id}/expire`, which works only while the session is `open` ([Expire a Checkout Session](https://docs.stripe.com/api/checkout/sessions/expire)). If Stripe reports the session is complete, don't release; wait for the webhook.
- **PayPal:** capture is server-initiated. The capture route must first move the reservation conditionally from `HELD` to `COMMITTING` (or a capture claim), and must refuse to capture a `RELEASED` reservation.

A late payment is still possible through asynchronous payment methods or provider edge cases. It is handled by row 7 of the state table.

**Webhooks move the reservation in the same transaction as the order.** Row 6 is one `TransactWriteItems`:

- order `pending` → `paid`
- reservation `HELD` → `COMMITTING`, removing the `INVHOLD` keys
- COMMIT job `Put` with `attribute_not_exists`, indexed under `INVJOB#OPEN`

Send the SQS message after the transaction commits. If the send fails, the open-job sweeper re-enqueues the job.

**Fulfillment gate.** The admin "ship" action requires the COMMIT job to be `COMPLETED` (`inventory_state = committed`). A `paid` order with `commit_pending` or `needs_attention` cannot ship until the job succeeds or an operator resolves it.

## Inventory Acceptance Tests

Run these in dev against sandbox providers and dev InvenTree:

- Two concurrent checkouts for the last unit: exactly one order is created, and the other gets 409. Repeat with a kit and a separately sold component that share the last unit of one part.
- A kit with N components where one is short: no order is written and no projection changes.
- A stale projection (sync stopped for more than 20 minutes) returns 503, and a missing `STOCK#` item or mapping `ERROR` returns 503 or 409, never success.
- A sync running concurrently with checkouts, releases, and commit completion keeps `available_qty = observed_qty - reserved_qty` after every step, with no negative `available_qty` in any sampled state.
- Kill the COMMIT worker after the InvenTree request but before completion: the retry finds the tracking entry by `job_key` and never moves stock twice.
- Request a movement larger than the stock held: the job reaches `NEEDS_ATTENTION`, and InvenTree never clamps it into a partial transfer.
- A duplicate webhook, and a webhook arriving after expiry: payment transitions happen once, and the late payment follows row 7.
- A refund before commit, after commit, and after shipping follows rows 11, 13, and 15. Shipped goods are never restocked.
- A manual InvenTree adjustment and a quarantine status change are reflected on the next sync. Damaged, returned, and attention-status stock is excluded.
- Reconciliation detects each seeded drift from its table, and auto-repairs only the projection arithmetic.
- Prove the relative update `SET available_qty = available_qty + :adj` with conditions on `observed_qty` and `pending_retire` entries against the real dev table, not only DynamoDB Local.
