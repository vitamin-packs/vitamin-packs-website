# DynamoDB Data Model

This is **proposed design** for the single table that the planned `dynamodb` Terraform module (`infra/modules/dynamodb`, not yet written) will create, and for how backend Lambda code should read and write it. Follow [Application architecture](application-architecture.md) for where backend code lives, and [Terraform conventions](terraform-conventions.md) if you need to change the table definition itself.

## Table

One table per environment, named `${project}-${environment}-data` (`project` is `vitamin-packs`, so `vitamin-packs-dev-data`; see [ADR-017](architecture-decisions.md#adr-017-terraform-project-value)). Key schema: hash key `PK` (string), range key `SK` (string). Billing mode `PAY_PER_REQUEST`. Two GSIs: `GSI1` and `GSI2`.

### Timestamps

Every stored timestamp is a UTC ISO 8601 string in one fixed format, `YYYY-MM-DDTHH:MM:SSZ` ([ADR-018](architecture-decisions.md#adr-018-timestamp-format)). Because the format is fixed-width, string order equals time order, so timestamps are compared directly in condition expressions and embedded directly in GSI sort keys. Writers format them with the `iso()` helper in `backend/shared`. Never store offsets, fractional seconds, or local time.

Exceptions:
- `ttl` is a Number in epoch seconds, because DynamoDB TTL only reads Number attributes ([TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/howitworks-ttl.html)).
- `sync_version` is an epoch-millisecond version counter, not a timestamp.
- Provider API fields that take epoch seconds, such as Stripe's `expires_at`, are converted at the API call.

## Entities

| Entity | PK | SK | Notes |
|---|---|---|---|
| Product | `PRODUCT#<sku>` | `PRODUCT#<sku>` | Kits and individual components share this shape. |
| Category | `CATEGORY#<tag>` | `METADATA` | Display label/description/sort order for a browsable tag. Carries `GSI1PK = CATEGORIES`, `GSI1SK = SORT#<sort_order zero-padded to 4>#<tag>` so the category list is one `Query`. |
| Order header | `ORDER#<orderId>` | `ORDER#<orderId>` | One per order. Stores `user_sub` (the owning customer's Cognito `sub`) for ownership checks. |
| Order line item | `ORDER#<orderId>` | `ORDER#<orderId>#ITEM#<sku>` | One per SKU in the order; `Query` on `PK` returns the header and all line items together. |
| User profile | `USER#<sub>` | `PROFILE` | `<sub>` is the Cognito user pool subject claim. Contact details, the Cognito email mirror, and the address book. See [Profile attributes](#profile-attributes). |
| Cart | `CART#<sub>` | `CART#<sub>` | In-progress cart, keyed by the caller's Cognito `sub` claim. See [Cart attributes](#cart-attributes). |
| Order refund | `ORDER#<orderId>` | `REFUND#<providerRefundId>` | One per provider refund; its conditional put makes `refunded_minor` count each refund once. |
| Payment event | `PAYEVT#<provider>#<eventId>` | `EVENT` | Ledger of verified Stripe/PayPal events and their processing state; see [Payment event](#payment-event-payevtprovidereventid--event) and [Payment processing](payment-processing.md#payment-event-ledger). |
| Stock projection | `STOCK#<partId>` | `PROJECTION` | One per InvenTree part that any SKU consumes. Derived from InvenTree; written only by inventory sync, checkout, release, and job completion. See [Inventory projection and reservations](#inventory-projection-and-reservations). |
| Order reservation | `ORDER#<orderId>` | `RESERVATION` | One per order: every part quantity the order holds against the projection. |
| Inventory job | `ORDER#<orderId>` | `INVJOB#<kind>` | One per order per movement kind (`COMMIT`, `UNCOMMIT`, `SHIP`). Durable, idempotent InvenTree stock movement. |
| Admin stock adjustment job | `ADJ#<adjustmentId>` | `INVJOB#ADJUST` | One per admin stock adjustment. Same job lifecycle; see [Inventory job](#inventory-job-orderorderid--invjobkind). |
| Inventory sync state | `SYNC#inventory` | `STATE` | Last start, last success, error counts, and `status` (`OK`, `ERROR`, or `LOCATIONS_UNCONFIGURED`; see [Eligible stock](inventree-integration.md#eligible-stock)). |

`<partId>` is the InvenTree part primary key in that environment. Dev and prod InvenTree have different keys, so part mappings are environment data and are never promoted from dev to prod.

### Product attributes

```
sku                     string  (also embedded in PK/SK)
name                    string
description             string
price                   number  (integer cents)
currency                string  (e.g. "USD")
images                  list<string>
bom                     list<{ sku: string, quantity: number }>   # kit display only; written by inventory sync from the InvenTree BOM
external_links          list<{ name: string, url: string, vendor: string, price: number }>  # non-stocked parts; never reserved
sellable_individually   bool
fulfillment_mode        string  ("STOCKED_PART" | "COMPONENTS"; required when sellable_individually)
inventree_part_id       number  (STOCKED_PART: the part sold; COMPONENTS: the kit assembly part whose BOM is used)
stock_requirements      map<partId, number>  # per one unit sold, in each part's InvenTree units; written only by inventory sync
mapping_version         string  (hash of mode, part IDs, quantities, units, BOM checksum, eligibility version)
mapping_status          string  ("PENDING" | "OK" | "ERROR"); checkout rejects anything but "OK"; an admin mapping change sets "PENDING" until the next sync validates it
mapping_error           string  (sanitized reason when mapping_status = "ERROR")
availability_hint       map { state: "in_stock" | "low" | "out" | "unknown", as_of: string }  # advisory display only
GSI2PK / GSI2SK         "INVMAP" / "SKU#<sku>"  (sellable products only; lets sync enumerate mapped SKUs)
category_tag            string  (single primary tag; see GSI1 note below)
difficulty              string  (e.g. "beginner" | "intermediate" | "advanced")
created_at              string  (ISO 8601)
updated_at              string  (ISO 8601)
```

`sellable_individually` and the GSI1 attributes work together (see below) to hide kit-only components from catalog browsing while keeping them directly retrievable for a kit's bill of materials.

Products carry **no stock quantity**. The former `inventory_count` attribute is removed: physical stock belongs to InvenTree, and sellable availability lives on the part-keyed stock projection. Admin product forms must not accept or write quantities. `availability_hint` is a display convenience written by sync and is never read by checkout.

### Cart attributes

```
lines              list<{ sku: string, quantity: number }>   # at most 10 lines; quantity is a positive integer, validated server-side
version            number  (starts at 1; every cart write increments it, conditioned on the version the client read)
checkout_order_id  string  (set by the checkout transaction; absent otherwise)
updated_at         string  (ISO)
ttl                number  (epoch s: last write + 30 days; abandoned-cart expiry, duration is an open owner question)
```

Lifecycle (proposed, [ADR-019](architecture-decisions.md#adr-019-cart-schema-and-lifecycle)):
- `PUT /cart` replaces `lines`, conditioned on `version = :client_version AND attribute_not_exists(checkout_order_id)`. Otherwise it returns 409, and the client re-reads the cart. Every write, including checkout's, resets `ttl`, so a cart never expires while a hold (at most 72 hours) is open.
- Checkout sets `checkout_order_id` in its transaction (see [Checkout reservation](#checkout-reservation-pseudocode)). `GET /cart` returns it, so the storefront can resume the provider redirect or poll the order.
- The verified-payment transaction ([row 6](payment-processing.md#order-payment-and-inventory-states)) deletes the cart, conditioned on `attribute_not_exists(PK) OR checkout_order_id = :oid`.
- A release from `HELD` removes `checkout_order_id`, conditioned on `checkout_order_id = :oid`, so the customer can retry with the same lines. Releases after payment and late payments (row 7) do not touch the cart.
- The cart stays locked while a checkout is open. It unlocks only through payment or a release from `HELD`: a customer cancel (`POST /checkout/cancel`, [ADR-022](architecture-decisions.md#adr-022-customer-checkout-cancel)), a payment failure, a session failure, or hold expiry.

### Profile attributes

One item per customer. Addresses are embedded, so the whole profile is one read and one version counter, and changing the default address is atomic (proposed, [ADR-024](architecture-decisions.md#adr-024-customer-profile-and-account-self-service)).

```
email               string  (mirror of the Cognito email; written only by the account function from AdminGetUser, never from a request body)
email_verified      bool    (mirror of the Cognito attribute)
email_synced_at     string  (ISO)
display_name        string  (optional; 1–80 characters)
phone               string  (optional; E.164 ^\+[1-9]\d{6,14}$; an unverified contact number, not a Cognito attribute)
marketing_opt_in    bool    (created as false)
marketing_opt_in_at string  (ISO; set when opted in, removed when opted out)
addresses           map<addressId, Address>   # at most 5; addressId is a server-generated UUID
default_address_id  string  (a key of addresses; removed when that address is deleted)
version             number  (starts at 1; every write increments it, conditioned on the version the client read)
created_at          string  (ISO)
updated_at          string  (ISO)
deleted_at          string  (ISO; tombstone only, see Lifecycle)
ttl                 number  (epoch s; tombstone only: deleted_at + 2 days)
```

`Address`:

```
label           string  (optional; ≤ 40, e.g. "Home")
recipient_name  string  (1–100)
line1           string  (1–100)
line2           string  (optional; ≤ 100)
city            string  (1–60)
region          string  (≤ 60; state or province code; required when country = "US")
postal_code     string  (≤ 20; US: ^\d{5}(-\d{4})?$)
country         string  (ISO 3166-1 alpha-2; must be in SHIP_COUNTRIES, default ["US"], OPEN-10)
phone           string  (optional; E.164, for the courier)
created_at      string  (ISO)
updated_at      string  (ISO)
```

Request schemas are closed: unknown fields are rejected with 400. Strings are NFC-normalized and trimmed, and control characters are rejected. The item stays near 5 KB, well under the 400 KB item limit.

Lifecycle:
- `GET /account/profile` never creates the item. When it is missing, the handler returns an empty profile with `version: 0`. The first mutation creates it with `attribute_not_exists(PK)`, so no Cognito post-confirmation trigger is needed.
- Every mutation is conditioned on `version = :client_version AND attribute_not_exists(deleted_at)`. Otherwise it returns 409 `version_conflict`, and the client re-reads.
- Only the `account` function writes the item. Checkout reads it (see [Checkout reservation](#checkout-reservation-pseudocode)) and copies the chosen address onto the order. A later profile edit never changes a placed order.
- Account deletion replaces the item with a tombstone (`PK`, `SK`, `deleted_at`, `ttl`). The tombstone outlives the 30 minutes in which API Gateway still accepts the deleted user's access tokens, so those tokens can neither recreate the profile nor check out. See [Account deletion](backend-api.md#account-deletion).

### Order header attributes

```
user_sub            string  (owning customer's Cognito sub)
status              string  ("pending" | "payment_pending" | "paid" | "fulfilled" | "cancelled" | "refunded")
inventory_state     string  (see Payment processing)
total_minor         number  (integer cents, computed from server-side prices at checkout)
currency            string  (e.g. "USD")
created_at          string  (ISO)
provider            string  ("stripe" | "paypal"; set when the provider session/order is created)
provider_ref        string  (Stripe Checkout Session ID or PayPal order ID; set once, conditionally)
checkout_url        string  (Stripe session URL or PayPal payer-action link, for browser retries)
session_expires_at  string  (ISO; converted to epoch s for Stripe's `expires_at`; stored so a retried create is identical)
payment_ref         string  (Stripe PaymentIntent ID or PayPal capture ID; set with paid)
paid_at             string  (ISO)
refunded_minor      number  (sum of REFUND# items; created as 0)
refund_requested    bool    (refund arrived while COMMIT was IN_PROGRESS or FAILED)
dispute_state       string  ("open" | "won" | "lost"; absent when there is no dispute)
payment_exception   string  ("amount_mismatch" | "currency_mismatch" | "reference_mismatch" | "payee_mismatch" | "late_unreserved" | "unexpected_payment")
ship_to             map     (copy of the chosen profile Address without label, created_at, and updated_at; written once at checkout)
ship_to_address_id  string  (the profile addressId it was copied from; display only, never re-read)
contact_email       string  (the profile email mirror at checkout)
GSI2PK / GSI2SK     "USER#<sub>" / "ORDER#<created_at>#<orderId>"
GSI1PK / GSI1SK     "ORDERS#<status>" / "ORDER#<created_at>#<orderId>"   # admin order queues; see GSI1
```

`GSI1PK` always equals `ORDERS#` + the current `status`. Every write that sets `status`, whether the checkout `Put` or a conditional transition update, sets `GSI1PK` in the same expression. It is never a separate action, so no transaction budget changes. `GSI1SK` is written once at checkout.

Only the payment-event processor writes `status` payment transitions, `payment_ref`, `paid_at`, `refunded_minor`, `dispute_state`, and `payment_exception` (see [Payment processing](payment-processing.md#order-payment-and-inventory-states)). The admin fulfillment gate reads `status`, `inventory_state`, `dispute_state`, and `payment_exception`.

### Payment event (`PAYEVT#<provider>#<eventId>` / `EVENT`)

```
provider            string  ("stripe" | "paypal")
event_id            string  (provider event ID)
event_type          string
object_ref          string  (Stripe Checkout Session / charge / dispute ID, or PayPal order / capture / refund / dispute ID)
order_id            string  (when resolvable)
state               string  ("RECEIVED" | "PROCESSING" | "SUCCEEDED" | "IGNORED" | "FAILED" | "NEEDS_ATTENTION")
attempts            number
lease_owner         string, lease_until string   # 60 s processing lease
next_attempt_at     string  (ISO; backoff after FAILED)
last_error          string  (sanitized: error class, provider code, provider request ID)
outcome             string  (applied transition, "noop", or the mismatch reason)
received_at, processed_at   string  (ISO)
GSI2PK / GSI2SK     "PAYEVT#OPEN" / "<next_attempt_at>#<provider>#<eventId>"  (only while RECEIVED, PROCESSING, or FAILED)
ttl                 number  (epoch s: processed_at + 35 days; set only on SUCCEEDED or IGNORED)
```

The item never stores the webhook body, because the processor re-fetches the provider object. `SUCCEEDED` is written only inside the same transaction as the business effect, so a failure after the claim never suppresses the event. `NEEDS_ATTENTION` items keep no `ttl` until an operator resolves them.

## Inventory projection and reservations

InvenTree is the only authority for physical stock, locations, adjustments, and BOMs (see [InvenTree integration](inventree-integration.md#inventory-data-contract)). DynamoDB holds a **derived** per-part projection plus a reservation ledger. Nothing in DynamoDB is a physical count that people edit.

The projection is keyed by InvenTree part, not by SKU. A component sold individually and used in kits draws from one counter, so it can't be counted twice.

### Stock projection (`STOCK#<partId>` / `PROJECTION`)

```
part_id              number
part_ipn             string   (cross-check only)
units                string   (InvenTree part units; quantities below are in these units)
observed_qty         number   # eligible physical quantity InvenTree reported in the snapshot
reserved_qty         number   # sum of this part across reservations that are HELD, COMMITTING, or COMMITTED and not yet retired
available_qty        number   # invariant: observed_qty - reserved_qty; may go negative (alerted, blocks checkout)
pending_retire       map<orderId, { qty: number, completed_at: string }>  # movements confirmed in InvenTree but not yet in observed_qty; created as {}
source_snapshot_at   string   (ISO: start of the sync run that produced observed_qty; drives freshness)
sync_version         number   (epoch ms of that sync run; only increases)
synced_at            string   (ISO: when the sync wrote this item)
projection_status    string   ("OK" | "ERROR")
eligibility_version  string   (hash of the eligible-location and status policy used)
GSI2PK / GSI2SK      "INVSTOCK" / "PART#<partId zero-padded to 10>"
```

DynamoDB condition expressions cannot do arithmetic, so `available_qty` is stored and kept equal to `observed_qty - reserved_qty` by every writer. Writers change it only by relative `SET x = x + :v` updates, so concurrent checkouts and syncs never overwrite each other. An update expression evaluates every right-hand side against the item as it was before the update ([Update expressions](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.UpdateExpressions.html)).

| Writer | Change | Condition |
|---|---|---|
| Checkout (reserve) | `reserved += q`, `available -= q` | `projection_status = OK`, `source_snapshot_at >= now - freshness`, `available_qty >= q` |
| Release | `reserved -= q`, `available += q` | reservation state guard in the same transaction |
| Commit-job completion | adds `pending_retire.<orderId>` | `attribute_not_exists(pending_retire.<orderId>)` |
| Sync | `observed = new`, `reserved -= R`, `available += (new - old) + R`, removes retired entries | `observed_qty = old`, `sync_version < this run`, each retired entry still exists |

Here `R` is the sum of the retired `pending_retire` entries.

### Reservation (`ORDER#<orderId>` / `RESERVATION`)

```
state              string  ("HELD" | "COMMITTING" | "COMMITTED" | "RETIRED" | "RELEASED")
parts              map<partId, number>   # aggregated across all order lines
mapping_versions   map<sku, string>
created_at         string  (ISO)
expires_at         string  (ISO; meaningful only while HELD; 35 min, or 72 h after a PayPal PENDING capture)
capture_claim_until string (ISO; PayPal capture route's claim; the expiry sweeper skips a live claim)
committed_at       string  (ISO; set when the COMMIT job is confirmed)
retired_at         string  (ISO)
release_reason     string  ("session_failed" | "payment_failed" | "customer_cancelled" | "expired" | "refunded_before_commit" | "operator"; removed if a late payment re-reserves)
GSI2PK / GSI2SK    "INVHOLD" / "EXP#<expires_at>#<orderId>"  (only while HELD; removed on any transition)
```

`reserved_qty` counts a reservation while it is `HELD`, `COMMITTING`, or `COMMITTED`. It stops counting at exactly one of two points:

- **Released:** the release transaction runs, conditioned on the reservation state.
- **Retired:** the sync applies a snapshot that already reflects the physical movement, and removes the reservation's `pending_retire` entry in the same update.

A late payment for an order released with reason `expired` is the only way out of `RELEASED`. It is one transaction:
- the reservation moves `RELEASED` → `COMMITTING`, conditioned on `#s = RELEASED AND release_reason = expired`;
- each projection is re-reserved with the same conditions as checkout (`projection_status = OK`, fresh, `available_qty >= q`);
- the COMMIT job is `Put`, and the order moves to `paid`;
- the ledger item moves to `SUCCEEDED`.

If a projection condition fails, a second transaction sets the order to `paid` / `needs_attention` with `payment_exception = late_unreserved`, and leaves the reservation `RELEASED` for the operator (see [Payment processing](payment-processing.md#order-payment-and-inventory-states), row 7).

### Inventory job (`ORDER#<orderId>` / `INVJOB#<kind>`)

```
kind               string  ("COMMIT" | "UNCOMMIT" | "SHIP")
job_key            string  ("vp-<env>-<orderId>-<kind>"; written into InvenTree stock notes)
state              string  ("QUEUED" | "IN_PROGRESS" | "COMPLETED" | "FAILED" | "CANCELLED" | "NEEDS_ATTENTION")
plan               map<partId, number>
from_location_ids  list<number>, to_location_id number
attempts           number, next_attempt_at string (ISO), last_error string (sanitized)
lease_owner        string, lease_until string (ISO)
inventree_tracking_ids  list<number>   # evidence of the completed movement
created_at, completed_at  string  (ISO)
GSI2PK / GSI2SK    "INVJOB#OPEN" / "<created_at>#<orderId>#<kind>"  (only while not terminal)
```

An admin stock adjustment uses the same attributes with `PK = ADJ#<adjustmentId>`, `SK = INVJOB#ADJUST`, and these differences:

```
kind               "ADJUST"
job_key            "vp-<env>-adj-<adjustmentId>"
op                 string  (default "ADD" | "REMOVE" | "COUNT"; the offered set is an open owner decision)
part_id, location_id, quantity   (location in the environment's eligible allowlist)
actor_sub, reason  string  (audit: the admin's Cognito sub and the stated reason)
GSI2SK             "<created_at>#ADJ#<adjustmentId>#ADJUST"
```

A decrease larger than the part's `available_qty` is rejected with 409 before the item is written, and the worker checks it again when it plans. There is no admin override. See [Async job contracts](backend-api.md#async-job-contracts).

The job item is the durable record. The SQS message only wakes a worker. If the queue loses or delays a message, the job is still listed under `INVJOB#OPEN`, and a sweeper re-enqueues it.

### TTL

Do not use TTL to expire reservations. TTL deletes expired items "typically within a few days", and expired items still appear in reads until then ([TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/howitworks-ttl.html)). A deletion would also leave `reserved_qty` unreleased. A scheduled sweeper releases expired holds instead. Enable TTL (attribute `ttl`) only for disposable records: carts, profile tombstones (2 days after an account deletion), terminal payment events (35 days after processing, beyond the providers' retry and resend windows), and optional sync-run logs. Never set it on orders, refunds, reservations, jobs, or projections.

## Global Secondary Indexes

### GSI1 — catalog browsing and admin order queues

GSI1 carries three sparse key families. None collides with another:

| GSI1PK | GSI1SK | On | Used by |
|---|---|---|---|
| `CATEGORY#<tag>` | `PRICE#<price>#SKU#<sku>` | sellable products | category browsing, sorted by price |
| `CATEGORIES` | `SORT#<sort_order>#<tag>` | category items | the category list, and `GET /products` |
| `ORDERS#<status>` | `ORDER#<created_at>#<orderId>` | order headers | admin order lists and work queues |

#### Catalog

- `GSI1PK = CATEGORY#<tag>`
- `GSI1SK = PRICE#<price>#SKU#<sku>`

Only set `GSI1PK`/`GSI1SK` on a product item when `sellable_individually = true`. DynamoDB GSIs are sparse: an item that omits the GSI's key attributes simply does not appear in that index. Kit-only components therefore never show up in category browsing, while remaining fully reachable via `GetItem` on `PK`/`SK` for BOM lookups.

The current design supports one primary `category_tag` per product. If a product needs to appear under multiple tags later, add extra `CATEGORY#<tag>` marker items with the same `GSI1PK`/`GSI1SK` shape that point back to the product's `PK`/`SK` — don't duplicate the full product record.

`GET /products` (all sellable products) queries `GSI1PK = CATEGORIES`, then queries each `CATEGORY#<tag>` partition. Because every product has exactly one primary tag, the union has no duplicates. The response is public and cacheable, so serve it behind CloudFront caching.

#### Admin order queues

- `GSI1PK = ORDERS#<status>`
- `GSI1SK = ORDER#<created_at>#<orderId>`

Set on order header items only, and moved with every `status` change (see [Order header attributes](#order-header-attributes)). A `Query` on one status, newest first, gives the admin order list. The work queues are status partitions narrowed by a filter on the header:
- **Ready to ship:** `ORDERS#paid`, filtered on `inventory_state = committed`, `dispute_state` not `open`, and no `payment_exception` (the row-14 guard; the ship route re-checks it with a consistent read).
- **Needs attention:** `ORDERS#paid`, filtered on `inventory_state = needs_attention` or `attribute_exists(payment_exception)`.
- **Open checkouts:** `ORDERS#pending` and `ORDERS#payment_pending`.

Moving an item between partitions is one GSI delete and one put, both charged as GSI writes. GSI results are eventually consistent, so an admin action re-reads the header with `ConsistentRead=True` before acting. At this order volume a single partition per status is fine. The same 1,000-writes-per-second note as GSI2 applies.

### GSI2 — a user's order history

- `GSI2PK = USER#<sub>`
- `GSI2SK = ORDER#<created_at>#<orderId>`

Set only on order header items (not on line items), so a `Query` on `GSI2` returns one row per order, newest/oldest depending on `ScanIndexForward`. Appending the order ID makes the index key unique if two orders share the same timestamp.

### GSI2 overloads for inventory operations

GSI2 also carries five sparse, fixed-partition keys. None of them collides with `USER#<sub>`, and none needs a new index or Terraform change. The GSI2 projection must include the attributes the sweepers read, or `ALL`. Verify this when the `dynamodb` module is written.

| GSI2PK | GSI2SK | On | Used by |
|---|---|---|---|
| `INVMAP` | `SKU#<sku>` | sellable products | sync enumerates mapped SKUs |
| `INVSTOCK` | `PART#<partId>` | projections | sync and reconciliation enumerate parts |
| `INVHOLD` | `EXP#<expires_at>#<orderId>` | reservations while `HELD` | expiry sweeper |
| `INVJOB#OPEN` | `<created_at>#<orderId>#<kind>`, or `<created_at>#ADJ#<adjustmentId>#ADJUST` | non-terminal jobs | re-enqueue sweeper and reconciliation |
| `PAYEVT#OPEN` | `<next_attempt_at>#<provider>#<eventId>` | payment events while `RECEIVED`, `PROCESSING`, or `FAILED` | payment sweeper re-drive and alarms |

GSI reads are eventually consistent. Sweepers treat index results only as candidates. They re-read the base item with `ConsistentRead=True`, and their conditional writes enforce the state.

Order volume is small, so a single partition per key is acceptable. Revisit if holds exceed about 1,000 writes per second, the per-partition write limit.

## Access patterns

| Need | Operation |
|---|---|
| Get a product by SKU | `GetItem` on `PK=SK=PRODUCT#<sku>` |
| Browse a category, sorted by price | `Query` on `GSI1` with `GSI1PK=CATEGORY#<tag>` |
| List categories | `Query` on `GSI1` with `GSI1PK=CATEGORIES` |
| List all sellable products (`GET /products`) | list categories, then `Query` each `GSI1PK=CATEGORY#<tag>` |
| List all products, including kit-only components (admin) | paginated `Scan` with `FilterExpression begins_with(PK, "PRODUCT#")`; see [Admin listing and reporting](#admin-listing-and-reporting) |
| Admin order list / work queue by status | `Query` on `GSI1` with `GSI1PK=ORDERS#<status>`, `ScanIndexForward=False`, plus the queue filter |
| Get an order and its line items | `Query` on `PK=ORDER#<orderId>` |
| List a user's orders | `Query` on `GSI2` with `GSI2PK=USER#<sub>` |
| Get or update a cart | `GetItem`/`PutItem` on `PK=SK=CART#<sub>` |
| Get or update a profile | `GetItem`/`UpdateItem` on `PK=USER#<sub>`, `SK=PROFILE` (version guard) |
| Check for open checkouts before account deletion | `Query` on `GSI2` with `GSI2PK=USER#<sub>`, then a `ConsistentRead` of each candidate `pending` or `payment_pending` header |
| Reserve stock and create a pending order | one `TransactWriteItems` (see [Checkout reservation](#checkout-reservation-pseudocode)) |
| Get an order's reservation and jobs | `Query` on `PK=ORDER#<orderId>` (header, lines, `RESERVATION`, `INVJOB#*`) |
| Read a part's availability | `GetItem` on `PK=STOCK#<partId>`, `SK=PROJECTION` (`ConsistentRead` for writers) |
| Enumerate mapped SKUs / projected parts | `Query` on `GSI2` with `GSI2PK=INVMAP` / `INVSTOCK` |
| Find expired holds | `Query` on `GSI2` with `GSI2PK=INVHOLD`, `GSI2SK < EXP#<now ISO>` |
| Find open inventory jobs | `Query` on `GSI2` with `GSI2PK=INVJOB#OPEN` |
| Claim or check a payment event | `UpdateItem` on `PK=PAYEVT#<provider>#<eventId>`, `SK=EVENT` (conditional on state and lease) |
| Find payment events due for re-drive | `Query` on `GSI2` with `GSI2PK=PAYEVT#OPEN`, `GSI2SK < <now ISO>` |
| Find an order by provider reference | read `order_id` from the fetched provider object (`client_reference_id`, `custom_id`), then `GetItem`; no index needed |
| Sync health | `GetItem` on `PK=SYNC#inventory`, `SK=STATE` |

## Checkout transaction budget

`TransactWriteItems` accepts at most 100 actions (4 MB aggregate), and no two actions may target the same item ([TransactWriteItems](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_TransactWriteItems.html)). Checkout therefore aggregates requirements per part before writing, and uses:

- 1 order header `Put`
- L line-item `Put`s
- L product `ConditionCheck`s (price and `mapping_version` unchanged)
- 1 reservation `Put`
- 1 cart `Update` (version guard)
- P projection `Update`s, one per distinct part

That is `3 + 2L + P` actions. The profile read and the `ship_to` snapshot add no action: the order holds a copy, so a concurrent profile edit is harmless. Enforce **L ≤ 10 lines and P ≤ 75 distinct parts** (at most 98 actions). Reject larger carts with 400 before writing. Adjust these limits only while keeping the total at 100 or less.

## Admin listing and reporting

DynamoDB stays the only application database ([ADR-025](architecture-decisions.md#adr-025-dynamodb-remains-the-application-database)). The admin app's list and report needs are met like this:

- **Orders:** the `ORDERS#<status>` partitions on GSI1 (see [Admin order queues](#admin-order-queues)), paginated with `LastEvaluatedKey` returned as an opaque cursor.
- **Products:** a paginated `Scan` filtered on `begins_with(PK, "PRODUCT#")`. A Scan reads, and is charged for, every item in the table. At a few thousand items that is a few cents a month for one admin user. Replace it with a sparse key if the table grows past about 50 MB or the page takes more than about a second.
- **Reports** (sales by SKU or month, refund totals, dispute counts): not built yet. The first version is an admin route that queries the `ORDERS#paid`, `ORDERS#fulfilled`, and `ORDERS#refunded` partitions for a `created_at` range (a `GSI1SK` `BETWEEN`), and aggregates in Lambda. If reporting later needs ad-hoc queries, use DynamoDB incremental export to S3 and query it with Athena. That needs point-in-time recovery, which the delivery plan already requires for the table ([Phase 4](development-and-deployment-plan.md#phase-4-application-infrastructure)), and no change to the table design. It is **not built**.

Never add a SQL copy of the table for reporting without a new decision: see ADR-025.

## Cost drivers

On-demand billing charges per request. Storage stays inside the free 25 GB. At the expected volume, the table costs a few dollars a month in prod and about nothing in idle dev. The main driver is the [inventory sync](#inventory-sync-pseudocode): every run writes every projection, because each write refreshes `source_snapshot_at` for the checkout freshness check. That is one write per part per run, or about 8,640 × (number of parts) writes a month. GSI2 doubles it when its projection includes the changed attributes. Watch the per-run write count in the sync metrics. A transactional write costs two write units per item. Checkout, payment, and release volumes are too small to matter.

## Dev seed data

`scripts/seed-dev.py` is planned; it does not exist in the repository yet. When written, it loads the development catalog only after the dev table exists. It creates a small catalog, categories (with their `CATEGORIES` GSI1 keys), kit display BOMs, and kit-only components, and deliberately omits `GSI1PK`/`GSI1SK` for the kit-only records so they cannot appear in the public catalog.

- It must not write `inventory_count`, `STOCK#` projections, reservations, or jobs. Projections come only from an inventory sync against dev InvenTree.
- It writes `fulfillment_mode` and `inventree_part_id` for dev InvenTree parts that the operator created. Those IDs are dev-specific and passed in as a mapping file, never guessed from names.
- It leaves `stock_requirements`, `mapping_version`, and `mapping_status` to the sync. The first sync validates them.

```sh
python3 scripts/seed-dev.py --table-name "$(terraform -chdir=infra/dev output -raw data_table_name)" --part-map dev-part-map.json
```

Do not run this script against production: it is sample data and uses unconditional `PutItem` writes.

**Migrating a table that already has `inventory_count`.** No deployed table was verified. If one exists:
1. Disable checkout.
2. Record the old values for audit.
3. `REMOVE inventory_count` from every product.
4. Set the mapping attributes.
5. Run a full sync and reconciliation.
6. Re-enable checkout.

Never load old `inventory_count` values into InvenTree or the projection unless the owner confirms they are physical counts, and then only as an audited InvenTree stock count.

### Example: fetch a product (boto3)

```python
import boto3

table = boto3.resource("dynamodb").Table(TABLE_NAME)

def get_product(sku: str) -> dict | None:
    response = table.get_item(Key={"PK": f"PRODUCT#{sku}", "SK": f"PRODUCT#{sku}"})
    return response.get("Item")
```

### Example: browse a category by price (boto3)

```python
from boto3.dynamodb.conditions import Key

def browse_category(tag: str) -> list[dict]:
    response = table.query(
        IndexName="GSI1",
        KeyConditionExpression=Key("GSI1PK").eq(f"CATEGORY#{tag}"),
    )
    return response["Items"]
```

### Checkout reservation (pseudocode)

This is design pseudocode, not a finished boto3 call. It shows the actions and conditions that the implementation must preserve.

```python
def checkout(sub, cart_version, address_id, provider):
    cart = get_cart(sub, consistent=True)                        # 409 if cart.version != cart_version
    if cart.checkout_order_id:                                   # browser retry after success
        return existing_checkout(cart.checkout_order_id)
    profile = get_profile(sub, consistent=True)                  # 409 "address_required" if missing or tombstoned
    address = profile.addresses.get(address_id)                  # 409 "address_required" if absent
    require(address.country in SHIP_COUNTRIES)                   # else 400
    products = batch_get_products(cart.skus, consistent=True)
    for p in products:
        require(p.sellable_individually and p.mapping_status == "OK")   # else 409 "unavailable"
    need = defaultdict(Decimal)                                  # partId -> quantity in part units
    for line in cart.lines:                                      # quantity: positive integer, server-validated
        for part_id, per_unit in products[line.sku].stock_requirements.items():
            need[part_id] += per_unit * line.quantity
    require(len(cart.lines) <= 10 and len(need) <= 75)           # transaction budget

    order_id, now = new_uuid(), utc_now()                        # iso() formats YYYY-MM-DDTHH:MM:SSZ
    expires_at = iso(now + HOLD)                                 # 35 min; see Payment processing
    fresh_after = iso(now - FRESHNESS)                           # 20 min in prod
    actions = [
        Put(order_header(order_id, sub, status="pending", inventory_state="reserved",
                         total_minor=sum_of_lines, currency=currency, refunded_minor=0,
                         created_at=iso(now),
                         GSI1PK="ORDERS#pending", GSI1SK=f"ORDER#{iso(now)}#{order_id}",
                         ship_to=snapshot(address), ship_to_address_id=address_id,   # copy; later edits never change it
                         contact_email=profile.email,
                         session_expires_at=iso(now + timedelta(seconds=1860))),  # >= 30 min after session creation (60 s margin); stored for idempotent retries
            cond="attribute_not_exists(PK)"),
        *[Put(order_line(order_id, l, products[l.sku].price)) for l in cart.lines],
        *[ConditionCheck(product_key(p.sku), cond="price = :price AND mapping_version = :mv")
          for p in products],
        Put(reservation(order_id, state="HELD", parts=need, expires_at=expires_at,
                        GSI2PK="INVHOLD", GSI2SK=f"EXP#{expires_at}#{order_id}"),
            cond="attribute_not_exists(PK)"),
        Update(cart_key(sub), "SET checkout_order_id = :oid, #ttl = :cart_ttl",
               cond="version = :v AND attribute_not_exists(checkout_order_id)"),
        *[Update(stock_key(part_id),
                 "SET reserved_qty = reserved_qty + :q, available_qty = available_qty - :q",
                 cond="projection_status = :ok AND source_snapshot_at >= :fresh AND available_qty >= :q",   # :fresh = fresh_after
                 return_values_on_condition_check_failure="ALL_OLD")
          for part_id, q in need.items()],
    ]
    for attempt in range(3):
        try:
            transact_write(actions, client_request_token=order_id)   # idempotent for 10 minutes
            return start_provider_session(order_id, expires_at)      # on failure: release(order_id, "session_failed")
        except TransactionCanceled as e:
            reasons = e.cancellation_reasons                         # same order as actions
            if any(r.code == "TransactionConflict" for r in reasons):
                sleep(jitter(attempt)); continue                     # concurrent last-unit buyer; re-evaluate
            failed = [a for a, r in zip(actions, reasons) if r.code == "ConditionalCheckFailed"]
            raise classify(failed)
            # missing STOCK# item, stale, or ERROR  -> 503 "inventory temporarily unavailable"
            # available_qty < q                     -> 409 with the affected SKUs (never quantities)
            # product price/mapping changed         -> 409 "cart changed, review and retry"
            # cart version / existing checkout      -> 409 or return the existing checkout
    raise ServiceUnavailable()
```

Last-unit concurrency: when two buyers race, DynamoDB serializes both transactions on the projection item. The winner decrements `available_qty`. The loser either fails the `available_qty >= :q` condition or gets `TransactionConflict`. On retry it re-evaluates against the new value and fails. A kit locks all its component items in one transaction, so it never holds a partial reservation.

### Inventory sync (pseudocode)

```python
def sync():
    run_ms = epoch_ms(); run_at = iso_from_ms(run_ms)            # taken BEFORE any InvenTree read
    retire_before = iso_from_ms(run_ms - CLOCK_MARGIN_S * 1000)
    for product in query_gsi2("INVMAP"):
        validate_and_write_mapping(product)                      # see InvenTree integration; ERROR fails closed
    for part_id in all_mapped_part_ids():
        try:
            new = eligible_quantity(part_id)                     # InvenTree read; see eligibility rules
        except MappingOrReadError as e:
            mark_projection_error(part_id, e)                    # only projection_status and error; quantities untouched
            continue
        for _ in range(3):
            cur = get_projection(part_id, consistent=True)
            if cur is None:
                put_projection(part_id, observed=new, reserved=0, available=new, pending_retire={},
                               cond="attribute_not_exists(PK)")
                break
            retire = {oid: e for oid, e in cur.pending_retire.items()
                      if e.completed_at < retire_before}             # movement finished before this snapshot began
            R = sum(e.qty for e in retire.values())
            try:
                update(stock_key(part_id),
                       "SET observed_qty = :new, reserved_qty = reserved_qty - :R, "
                       "available_qty = available_qty + :adj, source_snapshot_at = :run_at, "
                       "sync_version = :run_ms, synced_at = :now, projection_status = :ok "
                       "REMOVE " + ", ".join(f"pending_retire.#o{i}" for i in range(len(retire))),
                       cond="observed_qty = :old AND sync_version < :run_ms AND "
                            + " AND ".join(f"attribute_exists(pending_retire.#o{i})" for i in range(len(retire))),
                       values={":new": new, ":old": cur.observed_qty, ":R": R,
                               ":adj": (new - cur.observed_qty) + R})
                mark_reservations_retired(retire.keys())         # idempotent label update, state COMMITTED -> RETIRED
                break
            except ConditionalCheckFailed:
                continue                                         # a concurrent writer changed it; re-read
    write_sync_state(run_at, success_counts)
    write_availability_hints()
```

No transient oversell window:

- **Snapshot started before the movement:** `observed_qty` still includes the units, and the reservation still subtracts them.
- **Snapshot started after `completed_at`:** the units leave `observed_qty` and the reservation retires in the same item update.
- **Snapshot started before `completed_at` but read InvenTree after the movement:** availability is under-counted until the next sync. That is conservative, never an oversell.

Manual changes in InvenTree simply change `observed_qty` on the next sync. If they push `available_qty` below zero, checkout for that part stops and an alert fires.

### Commit-job completion (pseudocode)

```python
def complete_commit(order_id, worker_id, tracking_ids):
    now = iso(utc_now())                                         # after InvenTree confirmed the movement
    res = get_reservation(order_id, consistent=True)
    order = get_order(order_id, consistent=True)
    uncommit = []
    if order.refund_requested:                                   # refunded while COMMIT was in flight (row 12)
        uncommit = [Put(inventory_job(order_id, "UNCOMMIT", plan=res.parts, state="QUEUED",
                                      GSI2PK="INVJOB#OPEN"),
                        cond="attribute_not_exists(SK)")]
    transact_write([
        *uncommit,
        Update(job_key(order_id, "COMMIT"),
               "SET #s = :completed, completed_at = :now, inventree_tracking_ids = :ids REMOVE GSI2PK, GSI2SK",
               cond="#s = :in_progress AND lease_owner = :me"),
        Update(reservation_key(order_id), "SET #s = :committed, committed_at = :now",
               cond="#s = :committing"),
        Update(order_key(order_id), "SET inventory_state = :uncommit_pending_or_committed",
               cond="refund_requested = :seen_flag OR attribute_not_exists(refund_requested)"),  # re-read on conflict
        *[Update(stock_key(p), "SET pending_retire.#oid = :entry",
                 cond="attribute_not_exists(pending_retire.#oid)",
                 values={":entry": {"qty": q, "completed_at": now}})
          for p, q in res.parts.items()],
    ])
```

`reserved_qty` is unchanged here. It drops only when a sync observes the movement, as shown above.

The order update is conditioned on the `refund_requested` value that was read. If a refund lands between the read and the write, the transaction is cancelled, and the worker re-reads and retries the completion without repeating the InvenTree call (its lease is still held). When the flag is set, the order moves straight to `uncommit_pending` and the UNCOMMIT job is created in the same transaction. A refund can therefore never be lost while COMMIT is in flight.

### Release (pseudocode)

```python
def release(order_id, reason, from_states=("HELD",), ledger=None):
    res = get_reservation(order_id, consistent=True)
    order = get_order(order_id, consistent=True)
    unlock_cart = ([Update(cart_key(order.user_sub), "REMOVE checkout_order_id",
                           cond="checkout_order_id = :oid")]
                   if from_states == ("HELD",) else [])          # pre-payment release only; see Cart attributes
    transact_write([
        *unlock_cart,
        Update(reservation_key(order_id),
               "SET #s = :released, release_reason = :r REMOVE GSI2PK, GSI2SK",
               cond="#s IN (:from_states) AND (attribute_not_exists(capture_claim_until) "
                    "OR capture_claim_until < :now)"),          # exactly once; never under a live PayPal capture
        *([ledger_update(ledger, "SUCCEEDED")] if ledger else []),   # when a payment event drives the release
        Update(order_key(order_id), "SET #status = :cancelled_or_refunded, GSI1PK = :orders_status, "
                                    "inventory_state = :released"),       # GSI1PK tracks status
        *[Update(stock_key(p), "SET reserved_qty = reserved_qty - :q, available_qty = available_qty + :q")
          for p, q in res.parts.items()],
    ])
```

If only the cart action's condition fails (the cart was already unlocked or deleted), retry the release without it. A `ConditionalCheckFailed` on the reservation means it was already released or has moved past `HELD`, so treat the call as done. `COMMITTING` is releasable only when the COMMIT job is cancelled in the same transaction while still `QUEUED` (see [Payment processing](payment-processing.md#order-payment-and-inventory-states)).

### Example: writing a new sellable product vs. a kit-only component

```python
def put_product(item: dict) -> None:
    record = {
        "PK": f"PRODUCT#{item['sku']}",
        "SK": f"PRODUCT#{item['sku']}",
        **item,
    }

    # Sparse GSI1: only sellable products get GSI1 keys, so kit-only
    # components never appear in catalog browsing.
    if item["sellable_individually"]:
        record["GSI1PK"] = f"CATEGORY#{item['category_tag']}"
        record["GSI1SK"] = f"PRICE#{item['price']:012d}#SKU#{item['sku']}"
        # Sparse GSI2 overload: inventory sync enumerates mapped SKUs.
        record["GSI2PK"] = "INVMAP"
        record["GSI2SK"] = f"SKU#{item['sku']}"

    table.put_item(Item=record)
```

Note the zero-padded price in `GSI1SK` (`PRICE#{price:012d}#SKU#{sku}`) — DynamoDB sorts strings lexicographically, so a numeric price must be zero-padded to sort correctly as a number.
