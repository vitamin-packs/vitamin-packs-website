# DynamoDB Data Model

This describes the single-table design backing the `dynamodb` Terraform module (`infra/modules/dynamodb`) and how backend Lambda code should read and write it. Follow [Application architecture](application-architecture.md) for where backend code lives, and [Terraform conventions](terraform-conventions.md) if you need to change the table definition itself.

## Table

One table per environment, named `${project}-${environment}-data` (e.g. `diyhobbies-dev-data`). Key schema: hash key `PK` (string), range key `SK` (string). Billing mode `PAY_PER_REQUEST`. Two GSIs: `GSI1` and `GSI2`.

## Entities

| Entity | PK | SK | Notes |
|---|---|---|---|
| Product | `PRODUCT#<sku>` | `PRODUCT#<sku>` | Kits and individual components share this shape. |
| Category | `CATEGORY#<tag>` | `METADATA` | Display label/description/sort order for a browsable tag. |
| Order header | `ORDER#<orderId>` | `ORDER#<orderId>` | One per order. |
| Order line item | `ORDER#<orderId>` | `ORDER#<orderId>#ITEM#<sku>` | One per SKU in the order; `Query` on `PK` returns the header and all line items together. |
| User profile | `USER#<sub>` | `PROFILE` | `<sub>` is the Cognito user pool subject claim. |
| Cart | `CART#<userId>` | `CART#<userId>` | In-progress cart; consider a `ttl` attribute to expire abandoned carts. |
| Webhook receipt | `WEBHOOK#<provider>#<eventId>` | `RECEIVED` | Idempotency marker for Stripe/PayPal webhook events; see [Payment processing](payment-processing.md). |

### Product attributes

```
sku                     string  (also embedded in PK/SK)
name                    string
description             string
price                   number  (integer cents)
currency                string  (e.g. "USD")
images                  list<string>
bom                     list<{ sku: string, quantity: number }>   # kit-only: components this kit assembles from
external_links          list<{ name: string, url: string, vendor: string, price: number }>  # non-stocked parts
inventory_count         number
sellable_individually   bool
category_tag            string  (single primary tag; see GSI1 note below)
difficulty              string  (e.g. "beginner" | "intermediate" | "advanced")
created_at              string  (ISO 8601)
updated_at              string  (ISO 8601)
```

`sellable_individually` and the GSI1 attributes work together (see below) to hide kit-only components from catalog browsing while keeping them directly retrievable for a kit's bill of materials.

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

## Access patterns

| Need | Operation |
|---|---|
| Get a product by SKU | `GetItem` on `PK=SK=PRODUCT#<sku>` |
| Browse a category, sorted by price | `Query` on `GSI1` with `GSI1PK=CATEGORY#<tag>` |
| Get an order and its line items | `Query` on `PK=ORDER#<orderId>` |
| List a user's orders | `Query` on `GSI2` with `GSI2PK=USER#<sub>` |
| Get or update a cart | `GetItem`/`PutItem` on `PK=SK=CART#<userId>` |
| Decrement inventory when an order is placed | `UpdateItem` with a condition expression so writes fail closed instead of overselling |

## Dev seed data

Use `scripts/seed-dev.py` to load the development catalog only after the dev table exists. It creates a small catalog, categories, kit BOMs, and kit-only components. The script deliberately omits `GSI1PK`/`GSI1SK` for the kit-only records, so they cannot appear in the public catalog.

```sh
python3 scripts/seed-dev.py --table-name "$(terraform -chdir=infra/dev output -raw data_table_name)"
```

Do not run this script against production: it is sample data and uses unconditional `PutItem` writes.

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

### Example: conditional inventory decrement (prevents oversell)

```python
from botocore.exceptions import ClientError

def reserve_inventory(sku: str, quantity: int) -> bool:
    try:
        table.update_item(
            Key={"PK": f"PRODUCT#{sku}", "SK": f"PRODUCT#{sku}"},
            UpdateExpression="SET inventory_count = inventory_count - :qty",
            ConditionExpression="inventory_count >= :qty",
            ExpressionAttributeValues={":qty": quantity},
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
```

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

    table.put_item(Item=record)
```

Note the zero-padded price in `GSI1SK` (`PRICE#{price:012d}#SKU#{sku}`) — DynamoDB sorts strings lexicographically, so a numeric price must be zero-padded to sort correctly as a number.
