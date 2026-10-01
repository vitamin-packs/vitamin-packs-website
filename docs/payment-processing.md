# Payment Processing (Stripe + PayPal)

This describes how checkout and payment confirmation work across both supported providers. Follow [Application architecture](application-architecture.md) for where backend code lives and [DynamoDB data model](dynamodb-data-model.md) for the order schema referenced below.

This is proposed design, resolved on 2026-09-28 against the provider documentation listed in [References](#references). No backend code, provider account configuration, or webhook endpoint exists yet.

## Overview

The customer picks Stripe or PayPal at checkout. Both providers follow the same shape from the backend's point of view:

1. A `checkout` Lambda reserves stock, then creates a provider-side payment session/order from the cart and returns the URL the browser redirects to.
2. The customer completes payment with the provider. For PayPal, the backend then captures the approved order.
3. The **payment-event processor** is the only code that moves an order to `paid` or otherwise changes payment state:
   - It is invoked by the provider's verified webhook (`webhooks-stripe`, `webhooks-paypal`), or by the payment-event sweeper re-driving an event that failed.
   - It never trusts the webhook body or the browser. It **fetches the provider object server-to-server** (the Checkout Session, or the PayPal order) and validates it before acting ("fetch-then-act").
   - Never mark an order paid from the checkout Lambda, the capture route, or a frontend callback. Those can be skipped, retried, or spoofed.

## Dependencies and Provider Versions

| | Stripe | PayPal |
|---|---|---|
| Library | Official `stripe==15.6.1`, pinned exactly. It depends on `requests` and `typing_extensions`. | Thin in-house client, `backend/shared/payments/paypal_client.py` (planned), on `requests`. Pin one exact 2.32.x release, shared with Stripe's dependency. |
| API version | `2026-08-26.dahlia`, pinned by the SDK release. Create each webhook endpoint with the same API version. Upgrade the SDK and the endpoint version together, in dev first. | Orders v2 (spec 2.32), Payments v2, Webhooks v1 |
| Base URL | `https://api.stripe.com` in both environments. Test or live is selected by the key. | dev `https://api-m.sandbox.paypal.com`; prod `https://api-m.paypal.com`, from the Lambda environment variable `PAYPAL_API_BASE` |
| Timeouts | `stripe.StripeClient(api_key, http_client=stripe.RequestsClient(timeout=(3, 10)), max_network_retries=2)`. The SDK default is 80 s, which exceeds the API Gateway limit. | Connect 3 s, read 10 s (15 s for capture) |
| Retries | The SDK retries with backoff and honours `Stripe-Should-Retry`. Every `POST` carries our own `Idempotency-Key`. | Retry only GET, or POST with a `PayPal-Request-Id`, on connection errors, 5xx, and 409 `PREVIOUS_REQUEST_IN_PROGRESS`, at most 2 times with jittered backoff |

Rejected alternatives:
- **Standard-library HTTP:** it would mean hand-rolling Stripe signature verification, constant-time comparison, and retry logic.
- **`paypal-server-sdk`:** generated code that pulls in `apimatic-*` and `python-dotenv` and has no webhook helper.
- **`paypalrestsdk`:** legacy.

Lambda timeouts:
- Every payment function answering API Gateway stays under the HTTP API's 30-second integration limit. Use 25 s for `checkout` and 20 s for the webhook functions.
- Keep provider calls sequential and bounded so the worst case (one retry at each timeout) fits.

Every function fails fast at cold start when the environment and credentials disagree:
- **prod:** `PAYPAL_API_BASE` must be the live URL, and the Stripe key must start with `sk_live_` or `rk_live_`.
- **dev:** the sandbox URL and `sk_test_`/`rk_test_`.
- Every Stripe event's `livemode` must match the environment. A mismatch is rejected with 400 and counted.

## Secrets

Store each provider's credentials in AWS Secrets Manager, one secret per provider per environment named `${project}-${environment}-stripe` and `${project}-${environment}-paypal`, for example `vitamin-packs-dev-stripe` ([ADR-015](architecture-decisions.md#adr-015-payment-secret-naming)). The names follow the Terraform `${project}-${environment}-<purpose>` convention, so the deployer and secrets-operator permission sets' name scoping covers them. Never commit keys or hardcode them in Lambda source, per [Application architecture](application-architecture.md). Grant each Lambda's execution role read access to only the secret(s) it needs. Lambdas cache a secret for 5 minutes and re-read it once on a provider 401.

The `payments` Terraform module (planned) creates these secret containers but never creates a secret version. Populate them out of band after applying the environment stack. Use sandbox credentials in dev and live credentials in prod.

Stripe secret `${project}-${environment}-stripe`:

```json
{"api_key":"rk_test_...","webhook_secret":"whsec_...","webhook_secret_previous":null}
```

- Prefer a restricted key (`rk_`) with write access to Checkout Sessions, and read access to Refunds, PaymentIntents, Charges, and Disputes. Refunds are issued only in the dashboard ([ADR-023](architecture-decisions.md#adr-023-refunds-through-the-provider-dashboard)).
- `webhook_secret_previous` holds the old secret during a Stripe secret roll (up to 24 hours). Verification tries the current secret, then the previous one.

PayPal secret `${project}-${environment}-paypal`:

```json
{"client_id":"...","client_secret":"...","webhook_id":"...","merchant_id":"..."}
```

`merchant_id` is the store's PayPal merchant (payer) ID. Every capture's payee must match it.

## Order Status

Order header items (see [DynamoDB data model](dynamodb-data-model.md#order-header-attributes)) carry a `status` attribute with these values:

```
pending          # created at checkout, payment not yet confirmed
payment_pending  # provider accepted the payment but reports it pending (PayPal capture PENDING)
paid             # payment-event processor confirmed payment
fulfilled        # kit(s) shipped (SHIP movement completed)
cancelled        # checkout abandoned, payment failed, or hold expired
refunded         # fully refunded, or reversed by the provider
```

They also carry a separate `inventory_state`, because payment state and inventory state are independent:

```
reserved | released | commit_pending | committed | ship_pending | shipped | uncommit_pending | restocked | needs_attention
```

Money-only facts live in separate attributes and never change `status`:
- `refunded_minor` (partial refunds);
- `dispute_state` (`open`, `won`, `lost`);
- `payment_exception` (a payment that could not be applied automatically).

Every payment transition is a conditional update inside the processor's transaction, guarded by the prior `status` (for example, `#status IN (:pending, :payment_pending)`). The same update sets `GSI1PK = ORDERS#<new status>`, which drives the admin order queues ([Order header attributes](dynamodb-data-model.md#order-header-attributes)). A duplicate or out-of-order event therefore can't re-apply it. The one exception is a late payment on an order whose hold was released (`cancelled` with `release_reason = expired`). It is handled by row 7 below, never by the normal transition.

## Order, Payment and Inventory States

Reservation states are `HELD`, `COMMITTING`, `COMMITTED`, `RETIRED`, and `RELEASED`. Job states are `QUEUED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`, `CANCELLED`, and `NEEDS_ATTENTION`. Keys, conditions, and pseudocode are in [DynamoDB data model](dynamodb-data-model.md#inventory-projection-and-reservations). Movement mechanics are in [InvenTree integration](inventree-integration.md#physical-movements).

In the table:
- `q` is the part quantity the order reserved.
- `obs`, `res`, and `avail` are the projection's `observed_qty`, `reserved_qty`, and `available_qty`.
- "Verified payment" means the processor fetched the provider object and every [validation check](#payment-validation) passed.

| # | Event | Guard | Order `status` / `inventory_state` | Reservation | Job / InvenTree | Projection |
|---|---|---|---|---|---|---|
| 1 | Checkout succeeds | the transaction's conditions (fresh, `avail ≥ q`, price, mapping, cart version) | — → `pending` / `reserved` | — → `HELD` | none | `res += q`, `avail -= q` |
| 2 | Checkout rejected (insufficient, stale, missing, `ERROR`, changed cart) | transaction cancelled | no order written | none | none | none |
| 3 | Provider session/order creation fails permanently | reservation `HELD` | `pending` → `cancelled` / `released` | `HELD` → `RELEASED` (`session_failed`) | none | `res -= q`, `avail += q` |
| 4 | Verified payment failure (Stripe `checkout.session.async_payment_failed`, PayPal capture `DECLINED`/`FAILED`) | `HELD`, order `pending` or `payment_pending` | → `cancelled` / `released` | → `RELEASED` (`payment_failed`) | none | release |
| 4a | Customer cancels (`POST /checkout/cancel`, see [Customer Cancel](#customer-cancel)) | order `pending`, `HELD`, no live `capture_claim_until`, provider object confirmed unpayable first | → `cancelled` / `released` | → `RELEASED` (`customer_cancelled`) | none | release |
| 5 | Hold expires (sweeper) | `HELD`, `expires_at < now`, no live `capture_claim_until`, provider object confirmed unpayable first | → `cancelled` / `released` | → `RELEASED` (`expired`) | none | release |
| 6 | Verified payment | order `pending` or `payment_pending`, reservation `HELD` | → `paid` / `commit_pending` | → `COMMITTING` | COMMIT `QUEUED` and message sent | none (still reserved) |
| 6a | PayPal capture reports `PENDING` | order `pending`, reservation `HELD` | → `payment_pending` / `reserved` | stays `HELD`; `expires_at` = now + 72 h (INVHOLD key updated) | none | none |
| 6b | Pending capture completes | order `payment_pending` | row 6 | row 6 | row 6 | row 6 |
| 6c | Pending capture declined, or still pending at the 72-hour expiry | order `payment_pending` | row 4 or row 5 | → `RELEASED` | none | release |
| 6d | Provider object fails validation (amount, currency, reference, payee, `livemode`) | any | unchanged; `payment_exception` set | unchanged; the sweeper will not release it | none; alert, operator refunds | none |
| 7 | Verified payment after release (late) | order `cancelled`, reason `expired` | → `paid`; re-reserve in the same transaction: success → `commit_pending`; `TransactionCanceled` on a projection → `paid` / `needs_attention` with `payment_exception = late_unreserved` | `RELEASED` → `COMMITTING` (with `release_reason` removed), or unchanged | COMMIT, or operator (refund or backorder) | re-reserve (`fresh`, `avail ≥ q`), or none |
| 8 | COMMIT succeeds | job `IN_PROGRESS` with a matching lease; tracking evidence present | `paid` / `committed` | → `COMMITTED` | job → `COMPLETED`; transfer to the committed location | `pending_retire` entry added |
| 9 | Sync observes the commit | entry `completed_at` before the snapshot started | unchanged | → `RETIRED` | none | `obs -= q`, `res -= q`, `avail` unchanged |
| 10 | COMMIT fails permanently (shortfall, mapping error, mismatch) | retries exhausted or a discrepancy | `paid` / `needs_attention`; fulfillment blocked | stays `COMMITTING` (still counted) | `NEEDS_ATTENTION`; alert | none until the operator retries or cancels |
| 11 | Full refund after payment, COMMIT not started | job `QUEUED` | → `refunded` / `released` | `COMMITTING` → `RELEASED` (`refunded_before_commit`) | job → `CANCELLED` (same transaction) | release |
| 12 | Full refund after payment, COMMIT outcome not yet known | job `IN_PROGRESS` or `FAILED` (a `FAILED` job may have moved stock) | → `refunded`, `refund_requested = true`; `inventory_state` unchanged | unchanged | COMMIT continues; its completion transaction creates the UNCOMMIT job (row 13). `NEEDS_ATTENTION` → operator | none |
| 13 | Full refund after commit, not shipped | `committed` | → `refunded` / `uncommit_pending`, then `restocked` | unchanged (`COMMITTED` or `RETIRED`) | UNCOMMIT: transfer back | `obs` rises on the next sync |
| 14 | Admin ships | `status = paid`, `inventory_state = committed`, `dispute_state` not `open`, no `payment_exception` | → `ship_pending`, then `fulfilled` / `shipped` | unchanged | SHIP: remove from the committed location | none |
| 15 | Full refund or chargeback after shipping | `shipped` | → `refunded` / `shipped` | unchanged | none (no restock) | none |
| 15a | Partial refund | any paid state | unchanged; `refunded_minor` increases | unchanged | none (money only) | none |
| 15b | Dispute opened (Stripe `charge.dispute.created`, PayPal `CUSTOMER.DISPUTE.CREATED`) | any paid state | unchanged; `dispute_state = open`; blocks row 14 | unchanged | none; alert | none |
| 15c | Dispute lost, or PayPal `PAYMENT.CAPTURE.REVERSED` | any paid state | as a full refund: row 11, 12, 13, or 15 by inventory state | as that row | as that row | as that row |
| 16 | Return received | staff record it in InvenTree | unchanged; the admin notes the return | unchanged | staff put it in `Returns – inspection`, status RETURNED | none until staff move it to an eligible location with status OK |

Transaction rules:
- Every row is one conditional DynamoDB transaction that also moves the event ledger item to `SUCCEEDED` (see [Payment-event ledger](#payment-event-ledger)), or a sequence of such transactions in which each step is independently retryable and guarded by the prior state.
- There is no cross-system atomicity.
- InvenTree effects happen only inside jobs, and a payment event never proves that stock changed.

Transaction sizes stay within the 100-action limit:
- row 6 uses 5 items (ledger, order, reservation, job, cart);
- a release uses at most 5 + P (the cart action applies only to a release from `HELD`), and a late payment (row 7) at most 4 + P, with P ≤ 75 distinct parts.

Cancel routes:
- Row 4a's customer cancel of an unpaid checkout is `POST /checkout/cancel` ([ADR-022](architecture-decisions.md#adr-022-customer-checkout-cancel), [Customer Cancel](#customer-cancel)).
- A paid order has no cancel route ([ADR-023](architecture-decisions.md#adr-023-refunds-through-the-provider-dashboard)). Cancelling one means a full refund through the provider dashboard, which arrives as a refund event (rows 11–13, 15).

## Payment Validation

The processor applies rows 6–7 only when every check passes on the object it fetched. Any failure is row 6d.

**Stripe Checkout Session** (retrieved with `expand=["payment_intent"]`):
- `id == order.provider_ref`
- `client_reference_id == metadata["order_id"] == orderId`
- `mode == "payment"`
- `livemode` matches the environment
- `currency == order.currency.lower()`
- `amount_total == order.total_minor`
- `status == "complete"` and `payment_status == "paid"`

**PayPal order** (`GET /v2/checkout/orders/{id}`):
- `id == order.provider_ref`
- exactly one purchase unit, with `reference_id == custom_id == orderId` and `invoice_id == "vp-<env>-<orderId>"`
- `payee.merchant_id == secret.merchant_id`
- exactly one capture, with `status == "COMPLETED"` and `amount.currency_code == order.currency`
- `Decimal(amount.value)` converts exactly to `order.total_minor`, with no rounding

**Order state:** `status` is `pending` or `payment_pending` (row 6), or `cancelled` with `release_reason = expired` (row 7). Any other status with a verified payment, for example a second payment for a `paid` order, is recorded as `payment_exception = unexpected_payment` and alerted. It is never silently absorbed.

## Payment-Event Ledger

Stripe and PayPal both retry delivery for up to 3 days, deliver out of order, and can deliver duplicates. Stripe can even send two distinct Event objects for one object. The ledger records each verified event and its processing state. Only a successful business transaction can mark it done, so a crash never suppresses an event.

Item `PAYEVT#<provider>#<eventId>` / `EVENT` ([schema](dynamodb-data-model.md#payment-event-payevtprovidereventid--event)):

| State | Meaning | Suppresses reprocessing? |
|---|---|---|
| `RECEIVED` | verified and recorded, not yet claimed | no |
| `PROCESSING` | claimed by one invocation until `lease_until` (60 s) | only while the lease is live |
| `SUCCEEDED` | business effect committed **in the same transaction** as this state | yes |
| `IGNORED` | verified, but its type is not handled | yes |
| `FAILED` | processing raised; `next_attempt_at` set with backoff | no |
| `NEEDS_ATTENTION` | validation mismatch, or 10 attempts / 24 hours exhausted; pages the operator | yes, until an operator re-drives it |

Rules:
- **No separate "processed" marker.** `SUCCEEDED` is an action inside the business `TransactWriteItems`, conditioned on `#s = PROCESSING AND lease_owner = :me`. If the Lambda dies before that commits, nothing changed and the event is still claimable. If it dies after, the effect and the marker both exist.
- **Outbox.** The COMMIT or UNCOMMIT job item written in the same transaction is the durable outbox. The SQS message is sent after commit and only wakes a worker. If the send fails, the open-job sweeper re-enqueues the job.
- **Ordering.** Events never drive state directly. The processor re-reads the current provider object and the current order, and `decide()` chooses the transition from those. An older event arriving late re-reads the newest state, finds its transition already applied or no longer valid, and ends `SUCCEEDED` with `outcome = noop`.
- **Duplicates.** A second delivery of the same event ID finds `SUCCEEDED`/`IGNORED` and returns 200. A different event ID for the same object re-reads the state and becomes a no-op.
- **Unknown events.** The event is verified, recorded as `IGNORED`, and answered with 200, so the provider stops retrying. Endpoints subscribe only to the events [listed below](#subscribed-events).
- **Replay.** Stripe signatures are rejected after the SDK's 300-second tolerance, and each retry is re-signed. A replayed PayPal event is harmless: its event ID is in the ledger, and fetch-then-act makes its effect depend only on current provider state.
- **Retention.** The ledger `ttl` is set to terminal time + 35 days, which exceeds Stripe's 30-day manual-resend window and PayPal's 3-day retries.

```python
def handle_webhook(provider: str, raw_body: str, headers: dict) -> dict:
    evt = verify(provider, raw_body, headers)          # 400 on failure; never log the body or signature headers
    if evt.livemode != IS_PROD:                          # Stripe; PayPal is guarded by PAYPAL_API_BASE
        return respond(400)
    if evt.type not in SUBSCRIBED[provider]:
        put_ledger(evt, state="IGNORED", cond="attribute_not_exists(PK)")   # ConditionalCheckFailed is fine
        return respond(200)
    claim = claim_ledger(evt)
    # One conditional write:
    #   not exists | RECEIVED | FAILED | (PROCESSING AND lease_until < :now)
    #   -> PROCESSING, lease_owner = request id, lease_until = now + 60, attempts += 1, keep GSI2 open keys
    if claim.done:
        return respond(200)                              # SUCCEEDED / IGNORED / NEEDS_ATTENTION
    if claim.busy:
        return respond(409)                              # live lease elsewhere; the provider retries later
    try:
        process(provider, evt.object_ref, ledger=claim)
        return respond(200)
    except Exception as error:
        fail_ledger(claim, error=sanitize(error),        # FAILED, next_attempt_at = backoff(attempts)
                    needs_attention=claim.attempts >= 10 or claim.age > DAY)
        return respond(500)                              # the provider retries; the sweeper also re-drives


def process(provider: str, object_ref: str, ledger) -> None:
    snap = fetch_provider_object(provider, object_ref)   # Stripe session / PayPal order, server-to-server
    order, reservation, jobs = load_order(snap.order_id, consistent=True)
    action = decide(order, reservation, jobs, snap)       # pure function of the state table above
    if action.kind == "MISMATCH":
        transact([set_payment_exception(order, action.reason),
                  ledger_update(ledger, "NEEDS_ATTENTION", outcome=action.reason)])
        metric("PaymentMismatch")
        return
    try:
        transact([*action.writes,
                  ledger_update(ledger, "SUCCEEDED", outcome=action.kind,
                                cond="#s = :processing AND lease_owner = :me")])
    except TransactionCanceled as error:
        if lease_lost(error):
            raise                                        # another invocation owns the event now
        fresh = load_order(snap.order_id, consistent=True)
        if decide(*fresh, snap).kind == "NOOP":          # a concurrent event already applied it
            ledger_update(ledger, "SUCCEEDED", outcome="noop",
                          cond="#s = :processing AND lease_owner = :me")
            return
        raise                                            # state moved; retry with fresh data
    for job in action.enqueue:
        try_send_sqs(job)                                # failure tolerated; the open-job sweeper re-enqueues
```

The **payment sweeper** runs every 5 minutes. It queries GSI2 `PAYEVT#OPEN` for items whose `next_attempt_at` or lease has passed, claims each one exactly as above, and calls `process()`. It needs no stored payload, because `object_ref` is enough to re-fetch. It runs in the out-of-VPC `sweeper` function (see [Backend API](backend-api.md#functions-and-triggers)).

### Subscribed events

| Provider | Event | Processor action |
|---|---|---|
| Stripe | `checkout.session.completed`, `checkout.session.async_payment_succeeded` | fetch the session → row 6 or 7 |
| Stripe | `checkout.session.async_payment_failed` | row 4 |
| Stripe | `checkout.session.expired` | row 5 when still `HELD` |
| Stripe | `charge.refunded` | fetch the charge with its refunds → one `REFUND#` item per refund → row 11/12/13/15 when fully refunded, else 15a |
| Stripe | `charge.dispute.created`, `charge.dispute.closed` | 15b; `lost` → 15c; `won` → `dispute_state = won` |
| PayPal | `PAYMENT.CAPTURE.COMPLETED`, `PAYMENT.CAPTURE.PENDING`, `PAYMENT.CAPTURE.DECLINED` | GET the order (via the capture's `supplementary_data.related_ids.order_id`) → row 6, 6a, or 4 |
| PayPal | `PAYMENT.CAPTURE.REFUNDED` | GET the refund → one `REFUND#` item → full or 15a |
| PayPal | `PAYMENT.CAPTURE.REVERSED` | 15c |
| PayPal | `CUSTOMER.DISPUTE.CREATED`, `CUSTOMER.DISPUTE.RESOLVED` | 15b; resolved against the merchant → 15c |
| PayPal | `CHECKOUT.ORDER.APPROVED` | `IGNORED`; capture is server-initiated |

Refund exactly-once: each refund writes `ORDER#<orderId>` / `REFUND#<providerRefundId>` with `attribute_not_exists(SK)` and `ADD refunded_minor :amount` on the order in the same transaction. A refund counted once is never counted again, whichever event delivered it.

## Idempotency Keys

Keys are deterministic, so a retry after a crash reuses the same key. `expires_at` and every other request parameter are computed once and stored on the order, so a retried create sends identical parameters. Stripe errors if a reused key comes with different parameters.

| Call | Key | Provider retention |
|---|---|---|
| Stripe create Checkout Session | `Idempotency-Key: vp-<env>-<orderId>-session` | ≥ 24 h |
| Stripe expire session (hold sweeper and [customer cancel](#customer-cancel)) | none; retrieve the session and act on its `status` | — |
| PayPal create order | `PayPal-Request-Id: uuid5(VP_NAMESPACE, "<env>:<orderId>:create")` | 6 h |
| PayPal capture | `PayPal-Request-Id: uuid5(VP_NAMESPACE, "<env>:<orderId>:capture")` | 6 h |
| PayPal order fields | `reference_id = custom_id = orderId`; `invoice_id = vp-<env>-<orderId>` (unique per merchant, so a second payment for the order is refused with `DUPLICATE_INVOICE_ID`) | permanent |

The PayPal request ID is a 36-character UUID. That satisfies both the spec's 108-character field limit and the general idempotency guide's 38-character guidance.

Stripe caches the outcome of a request that began executing, including a 500. Treat a 500 or timeout as **indeterminate**: retry with the same key, and if that still fails, leave the order `pending`. The hold expiry sweeper resolves it by retrieving the session. Never retry with a new key.

## Stripe

Numbered flow:

1. `POST /checkout/stripe` (body `{cartVersion, addressId}`) runs the [checkout reservation](dynamodb-data-model.md#checkout-reservation-pseudocode) (row 1), which copies the chosen profile address onto the order as `ship_to`. It then creates the Checkout Session with:
   - `mode=payment`, `ui_mode=hosted_page`, `payment_method_types=["card"]` (cards plus card-based wallets; no delayed-notification methods);
   - `line_items` built from server-side prices;
   - `payment_intent_data.shipping` from the order's `ship_to` (for fraud signals). There is no `shipping_address_collection`: the address comes from the profile ([ADR-024](architecture-decisions.md#adr-024-customer-profile-and-account-self-service));
   - `client_reference_id=orderId`, and `metadata.order_id=orderId` on both the session and `payment_intent_data`;
   - `expires_at` = the order's ISO `session_expires_at` converted to epoch seconds (checkout time + 31 minutes, so it stays at least 30 minutes after the session is created);
   - `success_url` and `cancel_url` on the storefront;
   - `Idempotency-Key` as above.
2. A conditional update stores `provider = "stripe"`, `provider_ref` (the session ID), and `checkout_url` on the order (`attribute_not_exists(provider_ref) OR provider_ref = :id`). The URL is returned. A browser retry after success returns the stored URL (checkout pseudocode `existing_checkout`). A permanent creation failure is row 3.
3. The customer pays on Stripe and is redirected to `success_url?session_id={CHECKOUT_SESSION_ID}`. Stripe waits up to 10 s for our `checkout.session.completed` response before redirecting, so the webhook usually lands first.
4. `webhooks-stripe` verifies the event, records it in the ledger, retrieves the session, validates it, and runs row 6 → SQS.
5. The success page polls `GET /orders/{orderId}` until the status leaves `pending`. It never marks anything paid.
6. At expiry, the hold sweeper retrieves the session first:
   - `open` → `POST /v1/checkout/sessions/{id}/expire`, then release (row 5);
   - `expired` → release;
   - `complete` → call `process()` and do not release.

```python
import stripe

def stripe_client(secret: dict) -> stripe.StripeClient:
    # stripe==15.6.1 pins API version 2026-08-26.dahlia
    return stripe.StripeClient(
        secret["api_key"],
        http_client=stripe.RequestsClient(timeout=(3, 10)),
        max_network_retries=2,
    )

def verify_stripe(client: stripe.StripeClient, raw_body: str, headers: dict, secret: dict) -> stripe.Event:
    sig_header = headers.get("stripe-signature", "")
    for webhook_secret in filter(None, (secret["webhook_secret"], secret.get("webhook_secret_previous"))):
        try:
            return client.construct_event(raw_body, sig_header, webhook_secret)   # 300 s tolerance
        except stripe.SignatureVerificationError:
            continue
    raise InvalidSignature()
```

API Gateway may base64-encode the body (`isBase64Encoded`). Decode it to the exact raw bytes before verifying, because any re-serialization breaks the signature.

## PayPal

Numbered flow:

1. `POST /checkout/paypal` (body `{cartVersion, addressId}`) runs the checkout reservation (row 1), which copies the chosen profile address onto the order as `ship_to`. It gets an OAuth token (`POST /v1/oauth2/token`, `client_credentials`, cached until shortly before `expires_in`), then calls `POST /v2/checkout/orders` with:
   - `intent=CAPTURE`;
   - one purchase unit (`reference_id`, `custom_id`, `invoice_id`, amount from server-side prices);
   - `payment_source.paypal.experience_context` with `return_url`, `cancel_url`, `user_action=PAY_NOW`, and `shipping_preference=SET_PROVIDED_ADDRESS`;
   - `purchase_units[0].shipping` (name and address) from the order's `ship_to`, so the buyer cannot change it at PayPal and Seller Protection covers the shipped-to address. Verify the field shapes in the sandbox;
   - `PayPal-Request-Id` and `Prefer: return=representation`.
   It stores `provider = "paypal"` and `provider_ref` (the PayPal order ID) conditionally, and returns the `payer-action` link (`approve` on older responses).
2. The buyer approves on PayPal and returns to `return_url?token=<PayPal order ID>`. The storefront removes `token` from the address bar (see [Frontend applications](frontend-applications.md)) and calls the capture route.
3. `POST /checkout/paypal/capture` (`customer-jwt`) **captures but never marks paid**:
   1. Load the order. Return 404 if it is missing, the caller doesn't own it, or `token != provider_ref`.
   2. If `status` is `paid`, `payment_pending`, or `refunded`, return 200 with the current status. Repeated calls are harmless.
   3. **Claim** the reservation with one conditional update: `#s = HELD AND expires_at > :now_plus_60 AND (attribute_not_exists(capture_claim_until) OR capture_claim_until < :now)` → `SET capture_claim_until = :now_plus_120`.
      - If the reservation is `RELEASED`, return 409 "checkout expired". PayPal is never called, so an expired hold can never be charged.
      - If another claim is live, return 202.
   4. `POST /v2/checkout/orders/{id}/capture` with the capture `PayPal-Request-Id`, then map the result:
      - `COMPLETED`, `PENDING`, `ORDER_ALREADY_CAPTURED`, a timeout, or a 5xx → 202 `{"status": "processing"}`. The webhook or sweeper resolves the order by fetching it.
      - `INSTRUMENT_DECLINED` → 402 with the `payer-action` link, so the buyer can choose another funding source. Clear the claim.
      - `ORDER_NOT_APPROVED` or `ORDER_EXPIRED` → 409. Clear the claim.
   5. The storefront polls `GET /orders/{orderId}`.
4. `webhooks-paypal` verifies the event, records it in the ledger, GETs the order, validates it, and applies row 6, 6a, or 4.
5. At expiry, the hold sweeper skips reservations with a live `capture_claim_until`, then GETs the order first:
   - no capture (`CREATED`, `APPROVED`, `VOIDED`) → release (row 5);
   - capture `COMPLETED` or `PENDING` → call `process()`.

PayPal's created-order lifetime (3 hours by default) is longer than our 35-minute hold. That is safe, because only our capture route can take the money, and it refuses once the reservation leaves `HELD`.

Webhook verification uses PayPal's postback API with the body exactly as received. The raw string is spliced into the request, never re-serialized:

```python
import json

import requests

def verify_paypal(session: requests.Session, token: str, raw_body: str, headers: dict, webhook_id: str) -> bool:
    fields = {
        "auth_algo": headers["paypal-auth-algo"],
        "cert_url": headers["paypal-cert-url"],
        "transmission_id": headers["paypal-transmission-id"],
        "transmission_sig": headers["paypal-transmission-sig"],
        "transmission_time": headers["paypal-transmission-time"],
        "webhook_id": webhook_id,
    }
    body = json.dumps(fields)[:-1] + ', "webhook_event": ' + raw_body + "}"   # raw bytes, not re-serialized
    response = session.post(
        f"{PAYPAL_API_BASE}/v1/notifications/verify-webhook-signature",
        data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        timeout=(3, 10),
    )
    response.raise_for_status()                           # 5xx -> exception -> 500 -> PayPal retries
    return response.json().get("verification_status") == "SUCCESS"
```

A missing header or a status other than `SUCCESS` returns 400. PayPal's self-verification (CRC32 of the body plus the certificate at `paypal-cert-url`) is a later latency optimization. If it is adopted, it must validate the certificate chain and that the certificate host is a PayPal domain. Because of fetch-then-act, verification is defense in depth: a forged event can at most make us re-read PayPal's real state.

## Customer Cancel

A customer can cancel an unpaid checkout, which releases the hold and unlocks the cart ([ADR-022](architecture-decisions.md#adr-022-customer-checkout-cancel), row 4a). A paid order cannot be cancelled this way. It is refunded in the provider dashboard: see [ADR-023](architecture-decisions.md#adr-023-refunds-through-the-provider-dashboard).

`POST /checkout/cancel` (`customer-jwt`, `checkout` function) takes the closed body `{"orderId": "<uuid>"}`. Numbered flow:

1. `require_customer_sub(event)`, then validate the body before any read (400).
2. Load the order header with a consistent read. Return 404 if it is missing or its `user_sub` is not the caller's `sub`, exactly as the capture route does.
3. Branch on `status`:
   - `cancelled` → 200 with the current status. Repeated calls are harmless.
   - `payment_pending`, `paid`, `fulfilled`, or `refunded` → 409 with the current status.
   - Only `pending` continues.
4. Load the reservation with a consistent read:
   - `RELEASED` → 200;
   - any other state that is not `HELD` → 409;
   - a live `capture_claim_until` → 409 `{"status": "processing"}`;
   - no `provider_ref` on the order yet (the provider create is still in flight, or crashed) → 409 `{"status": "checkout_starting"}`. Expiry or row 3 resolves it.
5. **Make the provider object unpayable first.** This uses the same confirmation as the hold sweeper, kept in one `shared/payments/` helper:
   - **Stripe:** retrieve the session.
     - `open` → `POST /v1/checkout/sessions/{id}/expire`. If the expire fails because the session is no longer open, retrieve it again and act on the new status.
     - `expired` → continue.
     - `complete` → 409 `{"status": "processing"}`. `checkout` never calls `process()`: the webhook or the payment sweeper applies row 6.
   - **PayPal:** GET the order.
     - No capture (`CREATED`, `APPROVED`, `VOIDED`) → continue. After the release the capture route refuses, because the reservation is no longer `HELD`. A capture that started before the release holds a claim for 120 s, which is longer than this Lambda's 25 s timeout, so the release condition (no live claim) fails and nothing is released.
     - A capture that is `COMPLETED` or `PENDING` → 409 `{"status": "processing"}`.
   - A provider timeout or 5xx → 503. Nothing is released, and the customer may retry.
6. Run [`release(order_id, "customer_cancelled", from_states=("HELD",))`](dynamodb-data-model.md#release-pseudocode). It releases the projections and unlocks the cart in one transaction, with no ledger item.
   - If only the cart condition fails, retry without it, as for every release.
   - A `ConditionalCheckFailed` on the reservation means another writer won. Re-read the order and return 200 if it is `cancelled`, or 409 with its status otherwise (for example, `paid` after a payment raced the cancel).
7. Return 200 `{"status": "cancelled"}`. The storefront re-reads `GET /cart`, which now has no `checkout_order_id` and still has the same lines.

After a cancel:
- A Stripe `checkout.session.expired` event arrives for the session the route expired. Row 5 applies only while the reservation is `HELD`, so the event is a no-op and `release_reason` stays `customer_cancelled`.
- A payment for a customer-cancelled order is impossible in the normal flows: the Stripe session is expired before the release, and PayPal can only be captured by our route. If a provider edge case produces one anyway, row 7 does **not** apply, because it requires `release_reason = expired`. The payment is recorded as `payment_exception = unexpected_payment` and alerted, and the operator refunds it.

## Inventory

Reserve inventory in the checkout transaction ([Checkout reservation](dynamodb-data-model.md#checkout-reservation-pseudocode)) when the order is placed, not when payment is confirmed. Otherwise two customers could check out with the last unit before either pays. Everything after that follows the [state table](#order-payment-and-inventory-states).

**Hold duration:**
- **Stripe:** the Checkout Session `expires_at` is checkout time + 31 minutes, which keeps it at least 30 minutes after session creation. Stripe accepts 30 minutes to 24 hours and defaults to 24 hours ([Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create)).
- **Both providers:** the reservation's `expires_at` is now + 35 minutes.
- **PayPal:** the capture route refuses to capture within 60 seconds of `expires_at`.
- **PayPal `PENDING` capture:** extends the hold to 72 hours (row 6a).

**Expiry never races a payment.** An expiry sweeper runs every 5 minutes. For each candidate `INVHOLD` reservation, it first confirms with the provider that the order can no longer be paid, as described in the Stripe and PayPal flows above. It releases only after that. Its release is conditioned on the reservation still being `HELD` with no live capture claim.

A late payment requires a provider edge case, or a PayPal pending capture that outlived its 72-hour hold. With card-only Stripe sessions and server-initiated PayPal capture, the normal flows cannot produce one. Row 7 handles it.

**The processor moves the reservation in the same transaction as the order.** Row 6 is one `TransactWriteItems`:

- order `pending`/`payment_pending` → `paid`, recording `payment_ref` (PaymentIntent ID or PayPal capture ID) and `paid_at`
- reservation `HELD` → `COMMITTING`, removing the `INVHOLD` keys
- COMMIT job `Put` with `attribute_not_exists`, indexed under `INVJOB#OPEN`
- cart `Delete` conditioned on `attribute_not_exists(PK) OR checkout_order_id = :oid` ([Cart attributes](dynamodb-data-model.md#cart-attributes))
- ledger `PROCESSING` → `SUCCEEDED`

Send the SQS message after the transaction commits. If the send fails, the open-job sweeper re-enqueues the job.

**Refunds while a movement is in flight.** A COMMIT job that is `IN_PROGRESS` or `FAILED` may already have moved stock, because InvenTree adjustments have no idempotency key. Such a job is never cancelled. The refund sets `refund_requested` (row 12), and the [commit-completion transaction](dynamodb-data-model.md#commit-job-completion-pseudocode) creates the UNCOMMIT job. If COMMIT ends in `NEEDS_ATTENTION`, the operator resolves both.

**Fulfillment gate.** The admin "ship" action requires all of:
- `status = paid`;
- the COMMIT job `COMPLETED` (`inventory_state = committed`);
- no open dispute;
- no `payment_exception`.

An order in any other state cannot ship until the job succeeds or an operator resolves it.

## Logging, Metrics, and Recovery

**Logs** are structured JSON: provider, `event_id`, `event_type`, `order_id`, ledger state and outcome, `attempts`, provider HTTP status, and latency.

Never log:
- raw webhook bodies;
- `Stripe-Signature`, or `paypal-transmission-sig` / `paypal-cert-url`;
- OAuth access tokens, API keys, webhook secrets, or the `Authorization` header;
- payer names, emails, addresses, or phone numbers;
- card or funding-source details.

`sanitize()` keeps only the error class, the provider error code (for example `INSTRUMENT_DECLINED`), and the provider request ID. The PayPal `token` return parameter is an order ID and may be logged.

**Metrics** (CloudWatch embedded metric format):
- `WebhookSignatureFailure{provider}`
- `PaymentEvent{provider,outcome}`
- `PaymentEventOpenAge`
- `PaymentMismatch`
- `LatePayment`
- `CaptureResult{status}`
- `ProviderApiError{provider,operation}`
- `HoldReleased{reason}`

**Alarms** go to the `monitoring` module's SNS topic.

Page:
- any ledger item in `NEEDS_ATTENTION`;
- any `PaymentMismatch` or `LatePayment`;
- any open payment event older than 30 minutes.

Warn:
- more than 10 signature failures in 5 minutes (misconfiguration or probing);
- provider API errors above 5% over 15 minutes.

Stripe also emails the account owner when an endpoint keeps failing.

**Manual recovery:**
1. **Re-drive an event:** set its ledger item to `FAILED` with `next_attempt_at = now`. The sweeper processes it with a fresh provider fetch.
2. **Missing event:** resend it from the Stripe Dashboard (up to 15 days) or `stripe events resend` (up to 30 days), or with PayPal `POST /v1/notifications/webhooks-events/{id}/resend`.
3. **Order-level reconcile:** run `process()` for the order's `provider_ref`. It is idempotent.
4. **Refund** through the provider dashboard ([ADR-023](architecture-decisions.md#adr-023-refunds-through-the-provider-dashboard)). The resulting provider event drives the state change.
5. **Consistency uncertain:** disable checkout, keep all order, payment, and ledger records, and reconcile before resuming (see [InvenTree integration](inventree-integration.md#reconciliation-and-operations)).

## Inventory Acceptance Tests

Run these in dev against sandbox providers and dev InvenTree:

- Two concurrent checkouts for the last unit: exactly one order is created, and the other gets 409. Repeat with a kit and a separately sold component that share the last unit of one part.
- A kit with N components where one is short: no order is written and no projection changes.
- A stale projection (sync stopped for more than 20 minutes) returns 503, and a missing `STOCK#` item or mapping `ERROR` returns 503 or 409, never success.
- A sync running concurrently with checkouts, releases, and commit completion keeps `available_qty = observed_qty - reserved_qty` after every step, with no negative `available_qty` in any sampled state.
- Kill the COMMIT worker after the InvenTree request but before completion: the retry finds the tracking entry by `job_key` and never moves stock twice.
- Request a movement larger than the stock held: the job reaches `NEEDS_ATTENTION`, and InvenTree never clamps it into a partial transfer.
- A duplicate webhook, and a webhook arriving after expiry: payment transitions happen once, and the late payment follows row 7.
- A refund before commit, during an `IN_PROGRESS` or `FAILED` commit, after commit, and after shipping follows rows 11, 12, 13, and 15. Shipped goods are never restocked.
- A manual InvenTree adjustment and a quarantine status change are reflected on the next sync. Damaged, returned, and attention-status stock is excluded.
- Reconciliation detects each seeded drift from its table, and auto-repairs only the projection arithmetic.
- Prove the relative update `SET available_qty = available_qty + :adj` with conditions on `observed_qty` and `pending_retire` entries against the real dev table, not only DynamoDB Local.

## Payment Acceptance Tests

Run in dev with sandbox credentials only. Never use live credentials or real payments.

- **Signatures:** an invalid signature, a Stripe timestamp older than 300 s, a body re-serialized before verification, and a `livemode` mismatch are all rejected with 400 and no ledger write. A request signed with `webhook_secret_previous` verifies during a roll.
- **Duplicates and concurrency:** the same event delivered twice, and two deliveries processed concurrently, apply the transition once. One invocation gets 409 and the ledger ends `SUCCEEDED`. `checkout.session.completed` plus a second Event object for the same session also applies once.
- **Crash recovery:**
  - kill the processor after the ledger claim, before the transaction: the event stays claimable, and a provider retry or the sweeper completes it;
  - kill it after the transaction, before the SQS send: the open-job sweeper enqueues COMMIT.
- **Ordering:** deliver `checkout.session.expired` after `checkout.session.completed`, and a refund event before the paid event. The final state reflects the provider objects, not the arrival order.
- **Unknown event types** are `IGNORED` with 200.
- **Validation:** a seeded amount, currency, `client_reference_id`, `invoice_id`, or payee mismatch produces row 6d, no `paid`, a page, and a held reservation that the sweeper does not release.
- **PayPal capture:**
  - repeated capture calls return the same outcome, with one capture at PayPal;
  - `ORDER_ALREADY_CAPTURED` returns 202;
  - `INSTRUMENT_DECLINED` returns 402 with the approval link;
  - a capture after release returns 409 without calling PayPal;
  - the sweeper racing a live capture claim does not release.
- **Customer cancel** ([flow](#customer-cancel)):
  - cancelling with an open Stripe session expires the session, then releases. The projection is restored once and the cart is unlocked with its lines intact;
  - a cancel racing a `complete` Stripe session returns 409, and the order still becomes `paid` through the webhook;
  - a cancel during a live PayPal capture claim returns 409 and releases nothing;
  - a PayPal capture after a cancel returns 409 without calling PayPal;
  - a repeated cancel returns 200 each time and releases only once;
  - a `payment_pending` or `paid` order returns 409, and another customer's order returns 404;
  - a stubbed provider 5xx or timeout returns 503 and releases nothing;
  - a `checkout.session.expired` event after a cancel is a no-op.
- **Ship-to address:**
  - checkout with a missing, unknown, or another customer's `addressId` returns 409 `address_required` and writes nothing;
  - a country outside `SHIP_COUNTRIES`, or a region outside `SHIP_REGIONS` (for example `PR` or `AE`), returns 400;
  - the Stripe PaymentIntent and the PayPal order carry the order's `ship_to`, and PayPal does not let the buyer change it;
  - editing or deleting the profile address after checkout leaves the order's `ship_to` unchanged.
- **Pending:** a PayPal sandbox `PENDING` capture holds stock as `payment_pending`. Completion follows row 6; a decline or the 72-hour expiry releases it.
- **Idempotent creation:** a checkout Lambda retried after the provider call reuses the same Stripe session or PayPal order.
- **Refunds and disputes:** a partial refund changes only `refunded_minor`. A full refund in each inventory state follows its row. An opened dispute blocks shipping, and a lost one follows 15c.
- **Redaction:** scan the dev log group after the suite for emails, names, street addresses, phone numbers, `whsec_`, `sk_`/`rk_`, `Bearer`, and signature header values. There must be none.
- **Timeouts:** a stubbed provider that hangs makes the Lambda respond within API Gateway's 30 s limit, and the order stays recoverable.

## References

Checked 2026-09-28.

- Stripe:
  - [API versioning](https://docs.stripe.com/api/versioning) (current version `2026-08-26.dahlia`);
  - `stripe` 15.6.1 on PyPI and its source at tag `v15.6.1` (`stripe/_api_version.py`, `_http_client.py`, `_webhook.py`, `_stripe_client.py`);
  - [Idempotent requests](https://docs.stripe.com/api/idempotent_requests);
  - [Advanced error handling](https://docs.stripe.com/error-low-level);
  - [Webhooks](https://docs.stripe.com/webhooks) (signatures, tolerance, retries, ordering, duplicates);
  - [Event types](https://docs.stripe.com/api/events/types);
  - [Fulfill orders](https://docs.stripe.com/checkout/fulfillment?payment-ui=stripe-hosted);
  - [Create a Checkout Session](https://docs.stripe.com/api/checkout/sessions/create);
  - [Expire a Checkout Session](https://docs.stripe.com/api/checkout/sessions/expire).
- PayPal:
  - [Authentication](https://developer.paypal.com/api/rest/authentication/);
  - [Idempotency](https://developer.paypal.com/api/rest/reference/idempotency/);
  - Orders v2 OpenAPI 2.32 (`openapi/checkout_orders_v2.json` in `paypal/paypal-rest-api-specifications`), for `PayPal-Request-Id` retention, status enums, and field limits;
  - [Orders API standard use cases](https://developer.paypal.com/api/rest/integration/orders-api/api-use-cases/standard) (3-hour created-order lifetime);
  - [Orders v2 errors](https://developer.paypal.com/api/rest/reference/orders/v2/errors/);
  - [Webhooks](https://developer.paypal.com/api/rest/webhooks/rest/) (verification, 25 retries over 3 days);
  - [Webhook event names](https://developer.paypal.com/api/rest/webhooks/event-names/);
  - [Webhooks API v1](https://developer.paypal.com/docs/api/webhooks/v1/).
- AWS: [HTTP API quotas](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-quotas.html) (30-second maximum integration timeout).
