# DynamoDB Data Model

This describes the single-table design backing the `dynamodb` Terraform module (`infra/modules/dynamodb`) and how backend Lambda code should read and write it. Follow [Application architecture](application-architecture.md) for where backend code lives, and [Terraform conventions](terraform-conventions.md) if you need to change the table definition itself.

## Table

One table per environment, named `${project}-${environment}-data` (e.g. `diyhobbies-dev-data`). Key schema: hash key `PK` (string), range key `SK` (string). Billing mode `PAY_PER_REQUEST`. Two GSIs: `GSI1` and `GSI2`.

## Entities

| Entity | PK | SK | Notes |
|---|---|---|---|
| Product | `PRODUCT#<sku>` | `PRODUCT#<sku>` | Kits and individual components share this shape. |
| Category | `CATEGORY#<tag>` | `METADATA` | Display label/description/sort order for a browsable tag. |
| Order header | `ORDER#<orderId>` | `ORDER#<orderId>` | One per order. Stores `user_sub` (the owning customer's Cognito `sub`) for ownership checks. |
| Order line item | `ORDER#<orderId>` | `ORDER#<orderId>#ITEM#<sku>` | One per SKU in the order; `Query` on `PK` returns the header and all line items together. |
| User profile | `USER#<sub>` | `PROFILE` | `<sub>` is the Cognito user pool subject claim. |
| Cart | `CART#<sub>` | `CART#<sub>` | In-progress cart, keyed by the caller's Cognito `sub` claim; consider a `ttl` attribute to expire abandoned carts. |
| Order refund | `ORDER#<orderId>` | `REFUND#<providerRefundId>` | One per provider refund; its conditional put makes `refunded_minor` count each refund once. |
| Payment event | `PAYEVT#<provider>#<eventId>` | `EVENT` | Ledger of verified Stripe/PayPal events and their processing state; see [Payment event](#payment-event-payevtprovidereventid--event) and [Payment processing](payment-processing.md#payment-event-ledger). |
| Stock projection | `STOCK#<partId>` | `PROJECTION` | One per InvenTree part that any SKU consumes. Derived from InvenTree; written only by inventory sync, checkout, release, and job completion. See [Inventory projection and reservations](#inventory-projection-and-reservations). |
| Order reservation | `ORDER#<orderId>` | `RESERVATION` | One per order: every part quantity the order holds against the projection. |
| Inventory job | `ORDER#<orderId>` | `INVJOB#<kind>` | One per order per movement kind (`COMMIT`, `UNCOMMIT`, `SHIP`). Durable, idempotent InvenTree stock movement. |
| Admin stock adjustment job | `ADJ#<adjustmentId>` | `INVJOB#ADJUST` | One per admin stock adjustment. Same job lifecycle; see [Inventory job](#inventory-job-orderorderid--invjobkind). |
| Inventory sync state | `SYNC#inventory` | `STATE` | Last start, last success, and error counts for the sync. |

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
availability_hint       map { state: "in_stock" | "low" | "out" | "unknown", as_of: number }  # advisory display only
GSI2PK / GSI2SK         "INVMAP" / "SKU#<sku>"  (sellable products only; lets sync enumerate mapped SKUs)
category_tag            string  (single primary tag; see GSI1 note below)
difficulty              string  (e.g. "beginner" | "intermediate" | "advanced")
created_at              string  (ISO 8601)
updated_at              string  (ISO 8601)
```

`sellable_individually` and the GSI1 attributes work together (see below) to hide kit-only components from catalog browsing while keeping them directly retrievable for a kit's bill of materials.

Products carry **no stock quantity**. The former `inventory_count` attribute is removed: physical stock belongs to InvenTree, and sellable availability lives on the part-keyed stock projection. Admin product forms must not accept or write quantities. `availability_hint` is a display convenience written by sync and is never read by checkout.

### Order header attributes

```
user_sub            string  (owning customer's Cognito sub)
status              string  ("pending" | "payment_pending" | "paid" | "fulfilled" | "cancelled" | "refunded")
inventory_state     string  (see Payment processing)
total_minor         number  (integer cents, computed from server-side prices at checkout)
currency            string  (e.g. "USD")
created_at          number  (epoch s)
provider            string  ("stripe" | "paypal"; set when the provider session/order is created)
provider_ref        string  (Stripe Checkout Session ID or PayPal order ID; set once, conditionally)
checkout_url        string  (Stripe session URL or PayPal payer-action link, for browser retries)
session_expires_at  number  (epoch s sent to the provider; stored so a retried create is identical)
payment_ref         string  (Stripe PaymentIntent ID or PayPal capture ID; set with paid)
paid_at             number
refunded_minor      number  (sum of REFUND# items; created as 0)
refund_requested    bool    (refund arrived while COMMIT was IN_PROGRESS or FAILED)
dispute_state       string  ("open" | "won" | "lost"; absent when there is no dispute)
payment_exception   string  ("amount_mismatch" | "currency_mismatch" | "reference_mismatch" | "payee_mismatch" | "late_unreserved" | "unexpected_payment")
GSI2PK / GSI2SK     "USER#<sub>" / "ORDER#<createdAt>#<orderId>"
```

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
lease_owner         string, lease_until number   # 60 s processing lease
next_attempt_at     number  (epoch s; backoff after FAILED)
last_error          string  (sanitized: error class, provider code, provider request ID)
outcome             string  (applied transition, "noop", or the mismatch reason)
received_at, processed_at   number
GSI2PK / GSI2SK     "PAYEVT#OPEN" / "<next_attempt_at zero-padded to 10>#<provider>#<eventId>"  (only while RECEIVED, PROCESSING, or FAILED)
ttl                 number  (processed_at + 35 days; set only on SUCCEEDED or IGNORED)
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
pending_retire       map<orderId, { qty: number, completed_at: number }>  # movements confirmed in InvenTree but not yet in observed_qty; created as {}
source_snapshot_at   number   (epoch s: start of the sync run that produced observed_qty; drives freshness)
sync_version         number   (epoch ms of that sync run; only increases)
synced_at            number   (epoch s when the sync wrote this item)
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
created_at         number  (epoch s)
expires_at         number  (epoch s; meaningful only while HELD; 35 min, or 72 h after a PayPal PENDING capture)
capture_claim_until number (epoch s; PayPal capture route's claim; the expiry sweeper skips a live claim)
committed_at       number  (epoch s; set when the COMMIT job is confirmed)
retired_at         number
release_reason     string  ("session_failed" | "payment_failed" | "customer_cancelled" | "expired" | "refunded_before_commit" | "operator"; removed if a late payment re-reserves)
GSI2PK / GSI2SK    "INVHOLD" / "EXP#<expires_at zero-padded to 10>#<orderId>"  (only while HELD; removed on any transition)
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
attempts           number, next_attempt_at number, last_error string (sanitized)
lease_owner        string, lease_until number
inventree_tracking_ids  list<number>   # evidence of the completed movement
created_at, completed_at  number
GSI2PK / GSI2SK    "INVJOB#OPEN" / "<created_at zero-padded to 10>#<orderId>#<kind>"  (only while not terminal)
```

An admin stock adjustment uses the same attributes with `PK = ADJ#<adjustmentId>`, `SK = INVJOB#ADJUST`, and these differences:

```
kind               "ADJUST"
job_key            "vp-<env>-adj-<adjustmentId>"
op                 string  (default "ADD" | "REMOVE" | "COUNT"; the offered set is an open owner decision)
part_id, location_id, quantity   (location in the environment's eligible allowlist)
actor_sub, reason  string  (audit: the admin's Cognito sub and the stated reason)
GSI2SK             "<created_at zero-padded to 10>#ADJ#<adjustmentId>#ADJUST"
```

A decrease larger than the part's `available_qty` is rejected with 409 before the item is written, and the worker checks it again when it plans. There is no admin override. See [Async job contracts](backend-api.md#async-job-contracts).

The job item is the durable record. The SQS message only wakes a worker. If the queue loses or delays a message, the job is still listed under `INVJOB#OPEN`, and a sweeper re-enqueues it.

### TTL

Do not use TTL to expire reservations. TTL deletes expired items "typically within a few days", and expired items still appear in reads until then ([TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/howitworks-ttl.html)). A deletion would also leave `reserved_qty` unreleased. A scheduled sweeper releases expired holds instead. Enable TTL (attribute `ttl`) only for disposable records: carts, terminal payment events (35 days after processing, beyond the providers' retry and resend windows), and optional sync-run logs. Never set it on orders, refunds, reservations, jobs, or projections.

## Global Secondary Indexes

### GSI1 — catalog browsing by category/tag, sorted by price

- `GSI1PK = CATEGORY#<tag>`
- `GSI1SK = PRICE#<price>#SKU#<sku>`

Only set `GSI1PK`/`GSI1SK` on a product item when `sellable_individually = true`. DynamoDB GSIs are sparse: an item that omits the GSI's key attributes simply does not appear in that index. Kit-only components therefore never show up in category browsing, while remaining fully reachable via `GetItem` on `PK`/`SK` for BOM lookups.

The current design supports one primary `category_tag` per product. If a product needs to appear under multiple tags later, add extra `CATEGORY#<tag>` marker items with the same `GSI1PK`/`GSI1SK` shape that point back to the product's `PK`/`SK` — don't duplicate the full product record.

### GSI2 — a user's order history

- `GSI2PK = USER#<sub>`
- `GSI2SK = ORDER#<createdAt>#<orderId>`

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
| Get an order and its line items | `Query` on `PK=ORDER#<orderId>` |
| List a user's orders | `Query` on `GSI2` with `GSI2PK=USER#<sub>` |
| Get or update a cart | `GetItem`/`PutItem` on `PK=SK=CART#<sub>` |
| Reserve stock and create a pending order | one `TransactWriteItems` (see [Checkout reservation](#checkout-reservation-pseudocode)) |
| Get an order's reservation and jobs | `Query` on `PK=ORDER#<orderId>` (header, lines, `RESERVATION`, `INVJOB#*`) |
| Read a part's availability | `GetItem` on `PK=STOCK#<partId>`, `SK=PROJECTION` (`ConsistentRead` for writers) |
| Enumerate mapped SKUs / projected parts | `Query` on `GSI2` with `GSI2PK=INVMAP` / `INVSTOCK` |
| Find expired holds | `Query` on `GSI2` with `GSI2PK=INVHOLD`, `GSI2SK < EXP#<now>` |
| Find open inventory jobs | `Query` on `GSI2` with `GSI2PK=INVJOB#OPEN` |
| Claim or check a payment event | `UpdateItem` on `PK=PAYEVT#<provider>#<eventId>`, `SK=EVENT` (conditional on state and lease) |
| Find payment events due for re-drive | `Query` on `GSI2` with `GSI2PK=PAYEVT#OPEN`, `GSI2SK < <now>` |
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

That is `3 + 2L + P` actions. Enforce **L ≤ 10 lines and P ≤ 75 distinct parts** (at most 98 actions). Reject larger carts with 400 before writing. Adjust these limits only while keeping the total at 100 or less.

## Dev seed data

`scripts/seed-dev.py` is planned; it does not exist in the repository yet. When written, it loads the development catalog only after the dev table exists. It creates a small catalog, categories, kit display BOMs, and kit-only components, and deliberately omits `GSI1PK`/`GSI1SK` for the kit-only records so they cannot appear in the public catalog.

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
def checkout(sub, cart_version, provider):
    cart = get_cart(sub, consistent=True)                        # 409 if cart.version != cart_version
    if cart.checkout_order_id:                                   # browser retry after success
        return existing_checkout(cart.checkout_order_id)
    products = batch_get_products(cart.skus, consistent=True)
    for p in products:
        require(p.sellable_individually and p.mapping_status == "OK")   # else 409 "unavailable"
    need = defaultdict(Decimal)                                  # partId -> quantity in part units
    for line in cart.lines:                                      # quantity: positive integer, server-validated
        for part_id, per_unit in products[line.sku].stock_requirements.items():
            need[part_id] += per_unit * line.quantity
    require(len(cart.lines) <= 10 and len(need) <= 75)           # transaction budget

    order_id, now = new_uuid(), epoch_s()
    expires_at = now + HOLD_SECONDS                              # 35 min; see Payment processing
    fresh_after = now - FRESHNESS_SECONDS                        # 20 min in prod
    actions = [
        Put(order_header(order_id, sub, status="pending", inventory_state="reserved",
                         total_minor=sum_of_lines, currency=currency, refunded_minor=0,
                         session_expires_at=now + 1860),         # >= 30 min after session creation (60 s margin); stored for idempotent retries
            cond="attribute_not_exists(PK)"),
        *[Put(order_line(order_id, l, products[l.sku].price)) for l in cart.lines],
        *[ConditionCheck(product_key(p.sku), cond="price = :price AND mapping_version = :mv")
          for p in products],
        Put(reservation(order_id, state="HELD", parts=need, expires_at=expires_at,
                        GSI2PK="INVHOLD", GSI2SK=f"EXP#{expires_at:010d}#{order_id}"),
            cond="attribute_not_exists(PK)"),
        Update(cart_key(sub), "SET checkout_order_id = :oid",
               cond="version = :v AND attribute_not_exists(checkout_order_id)"),
        *[Update(stock_key(part_id),
                 "SET reserved_qty = reserved_qty + :q, available_qty = available_qty - :q",
                 cond="projection_status = :ok AND source_snapshot_at >= :fresh AND available_qty >= :q",
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
    run_ms = epoch_ms(); run_s = run_ms // 1000                  # taken BEFORE any InvenTree read
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
                      if e.completed_at < run_s - CLOCK_MARGIN_S}    # movement finished before this snapshot began
            R = sum(e.qty for e in retire.values())
            try:
                update(stock_key(part_id),
                       "SET observed_qty = :new, reserved_qty = reserved_qty - :R, "
                       "available_qty = available_qty + :adj, source_snapshot_at = :run_s, "
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
    write_sync_state(run_s, success_counts)
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
    now = epoch_s()                                              # after InvenTree confirmed the movement
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
    transact_write([
        Update(reservation_key(order_id),
               "SET #s = :released, release_reason = :r REMOVE GSI2PK, GSI2SK",
               cond="#s IN (:from_states) AND (attribute_not_exists(capture_claim_until) "
                    "OR capture_claim_until < :now)"),          # exactly once; never under a live PayPal capture
        *([ledger_update(ledger, "SUCCEEDED")] if ledger else []),   # when a payment event drives the release
        Update(order_key(order_id), "SET #status = :cancelled_or_refunded, inventory_state = :released"),
        *[Update(stock_key(p), "SET reserved_qty = reserved_qty - :q, available_qty = available_qty + :q")
          for p, q in res.parts.items()],
    ])
```

A `ConditionalCheckFailed` on the reservation means it was already released or has moved past `HELD`, so treat the call as done. `COMMITTING` is releasable only when the COMMIT job is cancelled in the same transaction while still `QUEUED` (see [Payment processing](payment-processing.md#order-payment-and-inventory-states)).

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
