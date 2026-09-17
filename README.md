# Advanced SQL Data Warehouse & Business Analytics — Central Superstore

A course mini-project that builds a **medallion-architecture data warehouse**
(staging → bronze → silver → gold) and a **star schema** on top of the
Central-region Superstore retail dataset, then layers KPI views, stored
procedures, and a business-analytics query catalog on top of it.

**Author:** Arsany Safwat Zakher Mousa Khalil
**Group:** ALX5_DAT3_S3 · **Instructor:** Eng. Walid Mohamed

## Business scenario

A retail organization wants to transform its operational data into an
analytical relational database for executive reporting and KPI monitoring,
using the Central region's transaction log (`Central_Superstore.csv`,
2,323 order-line rows, 2013–2016).

## Repo structure

```
Mini_Project_2_By_Arsany_Safwat.sql   # full build: schemas, all 4 layers,
                                        views, stored procedures, and the
                                        18-query analytics catalog
README.md                              # this file
```

## Architecture

All inside one `Superstore_DW` database, one schema per layer:

| Layer   | Schema    | What it is |
|---------|-----------|------------|
| Staging | `staging` | Raw load straight from the CSV, every column as text — zero transformation, zero load-failure risk |
| Bronze  | `bronze`  | Append-only historical copy, tagged with a load timestamp |
| Silver  | `silver`  | Typed, cleaned data with data-quality flag columns instead of silently dropped rows |
| Gold    | `gold`    | Star schema — `fact_sales` + 5 dimensions (`dim_customer`, `dim_product`, `dim_location`, `dim_date`, `dim_ship_mode`) |

**Star schema:**

```
                dim_customer
                     |
dim_ship_mode -- fact_sales -- dim_product
                     |
                dim_location        dim_date
```

`fact_sales` is at order-line grain (one row per Row ID), matching the source
file exactly.

## Data quality issue found and handled

**16 Product IDs map to two different Product Names each** (22 affected rows).
Example: `FUR-CH-10001146` appears as both "Global Value Mid-Back Manager's
Chair, Gray" and "Global Task Chair, Black."

**Rule applied:** the canonical name for a Product ID is the name attached to
that product's most recent Order Date. Every affected row is flagged
(`HasNameMismatch = 1`) in the silver layer rather than having its name
silently overwritten, so the discrepancy stays auditable.

No missing values, no duplicate rows, and no rows failing the validity rules
(positive quantity, discount between 0–1, non-negative sales, ship date not
before order date) were found elsewhere in the source file.

## What's built on top of the warehouse

- **2 KPI views** — `gold.vw_monthly_sales_kpi`, `gold.vw_customer_profitability`
- **2 stored procedures** — `gold.usp_get_sales_kpis_by_period` (date-range KPIs with period-over-period growth), `gold.usp_top_n_products_by_profit`
- **18 numbered analytical queries** covering joins, subqueries, CTEs, `CASE` statements, and window functions (`ROW_NUMBER`, `LAG`, `AVG() OVER()`)
- **A business-analytics section** — profitability, customer behavior, and sales-trend queries, each paired with a written insight
- **Indexes** on every foreign key of `gold.fact_sales`, plus a covering index for the heaviest reporting pattern

## How to run

1. Export `Central_Superstore.xlsx` to CSV.
2. Open `Mini_Project_2_By_Arsany_Safwat.sql` in SQL Server Management Studio (SQL Server 2017+ required for `TRY_CAST` and window-function usage).
3. Update the hard-coded path in the `BULK INSERT ... FROM` line to wherever you saved the CSV.
4. Run the script top to bottom. It creates the `Superstore_DW` database, every schema and table, the star schema, the KPI views/procedures, and loads the data.
5. Scroll to the analytics section to see the 18 queries and their business insights.

## Rubric self-check

| Requirement | Minimum | Delivered |
|---|---|---|
| Relational tables | 5 | 11 (staging + bronze + silver + 6 gold tables) |
| SQL queries | 15 | 18 |
| JOIN operations | 3 | 8+ |
| CTEs | 2 | 8 |
| Stored procedures | 1 | 2 |
| SQL views | 1 | 2 |
| CASE statements | 1 | 3 |
| Subqueries | 1 | 2, plus `NOT EXISTS`/`EXISTS` usage in the loads |
| Star schema with keys | Present | 5 dimensions + 1 fact, all FK-constrained |

## Key business insights

**Profitability:** Technology drives the region's profit ($33,697), Office
Supplies is solidly profitable ($8,880), but Furniture is a net loss
(-$2,871) — concentrated in the Furnishings and Tables sub-categories.
Discounts of 50%+ collectively lose -$40,793 across 456 order lines.

**Customer behavior:** 345 of 629 customers (55%) are repeat buyers.
Corporate customers have the highest average sale size ($234.76) and highest
total profit ($18,704) of the three segments.

**Sales trends:** Sales grew from $103,838 (2013) to $147,429 (2015), then
flattened into 2016 ($147,098) — but profit fell by more than half over that
same flat year ($19,899 → $7,551). Texas and Illinois are the two
highest-revenue states but are both net unprofitable overall.

## Tools
-Assistance of AI

-SQL Server (T-SQL)
