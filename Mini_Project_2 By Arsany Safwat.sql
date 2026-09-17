-- =====================================================================
-- Mini-Project 2: Advanced SQL Data Warehouse & Business Analytics
-- GROUP : ALX5_DAT3_S3
-- INSTRUCTOR : Eng/ Walid Mohamed
-- Dataset: Central_Superstore.xlsx (2,323 order-line rows)
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 0: Database and schema setup
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'Superstore_DW')
    CREATE DATABASE Superstore_DW;
GO

USE Superstore_DW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staging')
    EXEC('CREATE SCHEMA staging');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'bronze')
    EXEC('CREATE SCHEMA bronze');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
GO

-- ---------------------------------------------------------------------
-- STEP 1: STAGING LAYER
-- ---------------------------------------------------------------------
IF OBJECT_ID('staging.raw_sales', 'U') IS NULL
BEGIN
    CREATE TABLE staging.raw_sales (
        [Row ID]        NVARCHAR(255),
        [Order ID]      NVARCHAR(255),
        [Order Date]    NVARCHAR(255),
        [Ship Date]     NVARCHAR(255),
        [Ship Mode]     NVARCHAR(255),
        [Customer ID]   NVARCHAR(255),
        [Customer Name] NVARCHAR(255),
        [Segment]       NVARCHAR(255),
        [Country]       NVARCHAR(255),
        [City]          NVARCHAR(255),
        [State]         NVARCHAR(255),
        [Postal Code]   NVARCHAR(255),
        [Region]        NVARCHAR(255),
        [Product ID]    NVARCHAR(255),
        [Category]      NVARCHAR(255),
        [Sub-Category]  NVARCHAR(255),
        [Product Name]  NVARCHAR(500),   -- longest real name found is 127 chars; 500 gives headroom
        [Sales]         NVARCHAR(255),
        [Quantity]      NVARCHAR(255),
        [Discount]      NVARCHAR(255),
        [Profit]        NVARCHAR(255)
    );
END;
GO

-- Inserting the dataset : Central_Superstore.csv
TRUNCATE TABLE staging.raw_sales;
GO

BULK INSERT staging.raw_sales
FROM 'C:\Users\arsan\Downloads\Central_Superstore.csv'   -- <-- change to your real path
WITH (
    FIRSTROW = 2,               
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    CODEPAGE = '65001',         
    MAXERRORS = 0
);
GO

-- ---------------------------------------------------------------------
-- STEP 2: BRONZE LAYER
-- ---------------------------------------------------------------------
IF OBJECT_ID('bronze.sales', 'U') IS NULL
BEGIN
    CREATE TABLE bronze.sales (
        bronze_id       INT IDENTITY(1,1) PRIMARY KEY,    
        load_timestamp  DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
        [Row ID]        NVARCHAR(255),
        [Order ID]      NVARCHAR(255),
        [Order Date]    NVARCHAR(255),
        [Ship Date]     NVARCHAR(255),
        [Ship Mode]     NVARCHAR(255),
        [Customer ID]   NVARCHAR(255),
        [Customer Name] NVARCHAR(255),
        [Segment]       NVARCHAR(255),
        [Country]       NVARCHAR(255),
        [City]          NVARCHAR(255),
        [State]         NVARCHAR(255),
        [Postal Code]   NVARCHAR(255),
        [Region]        NVARCHAR(255),
        [Product ID]    NVARCHAR(255),
        [Category]      NVARCHAR(255),
        [Sub-Category]  NVARCHAR(255),
        [Product Name]  NVARCHAR(500),
        [Sales]         NVARCHAR(255),
        [Quantity]      NVARCHAR(255),
        [Discount]      NVARCHAR(255),
        [Profit]        NVARCHAR(255)
    );
END;
GO

INSERT INTO bronze.sales (
    [Row ID],[Order ID],[Order Date],[Ship Date],[Ship Mode],[Customer ID],
    [Customer Name],[Segment],[Country],[City],[State],[Postal Code],[Region],
    [Product ID],[Category],[Sub-Category],[Product Name],[Sales],[Quantity],
    [Discount],[Profit]
)
SELECT
    s.[Row ID],s.[Order ID],s.[Order Date],s.[Ship Date],s.[Ship Mode],s.[Customer ID],
    s.[Customer Name],s.[Segment],s.[Country],s.[City],s.[State],s.[Postal Code],s.[Region],
    s.[Product ID],s.[Category],s.[Sub-Category],s.[Product Name],s.[Sales],s.[Quantity],
    s.[Discount],s.[Profit]
FROM staging.raw_sales s
WHERE NOT EXISTS (
    SELECT 1 FROM bronze.sales b WHERE b.[Row ID] = s.[Row ID]
);
GO
-- =====================================================================
-- STEP 3: SILVER LAYER
-- =====================================================================

-- ---------------------------------------------------------------------
-- Data quality issue found during exploration (Step 1 of this project):
-- 16 Product IDs are associated with TWO different Product Names in the
-- source data (e.g. Product ID FUR-CH-10001146 appears as both
-- "Global Value Mid-Back Manager's Chair, Gray" and "Global Task Chair,
-- Black"). This looks like a naming correction that happened mid-way
-- through the data's history, with both old and new names surviving.
--
-- RULE WE'RE APPLYING: for each Product ID, the CANONICAL name is the
-- name attached to that product's MOST RECENT Order Date. Every row is
-- flagged (has_name_mismatch = 1) where its own recorded name doesn't
-- match the canonical one, so nothing is silently overwritten -- we can
-- always audit which rows were affected.
-- ---------------------------------------------------------------------

IF OBJECT_ID('silver.sales', 'U') IS NULL
BEGIN
    CREATE TABLE silver.sales (
        RowID               INT NOT NULL,
        OrderID             NVARCHAR(255),
        OrderDate           DATE,
        ShipDate            DATE,
        ShipMode            NVARCHAR(255),
        CustomerID          NVARCHAR(255),
        CustomerName        NVARCHAR(255),
        Segment             NVARCHAR(255),
        Country             NVARCHAR(255),
        City                NVARCHAR(255),
        State               NVARCHAR(255),
        PostalCode          NVARCHAR(50),
        Region              NVARCHAR(255),
        ProductID           NVARCHAR(255),
        Category            NVARCHAR(255),
        SubCategory         NVARCHAR(255),
        ProductName         NVARCHAR(500),   -- the row's own, as-recorded name
        CanonicalProductName NVARCHAR(500),  -- the cleaned, agreed-upon name for this Product ID
        Sales               DECIMAL(18,4),
        Quantity            INT,
        Discount            DECIMAL(5,2),
        Profit              DECIMAL(18,4),
        HasInvalidValue     BIT NOT NULL DEFAULT 0,
        HasNameMismatch     BIT NOT NULL DEFAULT 0,
        CONSTRAINT PK_silver_sales PRIMARY KEY (RowID)
    );
END;
GO

TRUNCATE TABLE silver.sales;
GO

-- De-duplicate bronze first: if the same Row ID was ever loaded twice
-- (e.g. the same source file re-imported), keep only its latest load.
WITH bronze_latest AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY [Row ID]
            ORDER BY bronze_id DESC
        ) AS rn
    FROM bronze.sales
    WHERE NULLIF(LTRIM(RTRIM([Row ID])), '') IS NOT NULL
),

-- Convert every text column to its real type. TRY_CAST returns NULL
-- instead of erroring out if a value can't be converted -- that failed
-- conversion becomes visible data (a NULL) rather than a crashed script.
cleaned AS (
    SELECT
        TRY_CAST(LTRIM(RTRIM([Row ID])) AS INT)                     AS RowID,
        NULLIF(LTRIM(RTRIM([Order ID])), '')                        AS OrderID,
        TRY_CAST(LTRIM(RTRIM([Order Date])) AS DATE)                AS OrderDate,
        TRY_CAST(LTRIM(RTRIM([Ship Date])) AS DATE)                 AS ShipDate,
        NULLIF(LTRIM(RTRIM([Ship Mode])), '')                       AS ShipMode,
        NULLIF(LTRIM(RTRIM([Customer ID])), '')                     AS CustomerID,
        NULLIF(LTRIM(RTRIM([Customer Name])), '')                   AS CustomerName,
        NULLIF(LTRIM(RTRIM([Segment])), '')                         AS Segment,
        NULLIF(LTRIM(RTRIM([Country])), '')                         AS Country,
        NULLIF(LTRIM(RTRIM([City])), '')                            AS City,
        NULLIF(LTRIM(RTRIM([State])), '')                           AS State,
        NULLIF(LTRIM(RTRIM([Postal Code])), '')                     AS PostalCode,
        NULLIF(LTRIM(RTRIM([Region])), '')                          AS Region,
        NULLIF(LTRIM(RTRIM([Product ID])), '')                      AS ProductID,
        NULLIF(LTRIM(RTRIM([Category])), '')                        AS Category,
        NULLIF(LTRIM(RTRIM([Sub-Category])), '')                    AS SubCategory,
        NULLIF(LTRIM(RTRIM([Product Name])), '')                    AS ProductName,
        TRY_CAST(LTRIM(RTRIM([Sales])) AS DECIMAL(18,4))            AS Sales,
        TRY_CAST(LTRIM(RTRIM([Quantity])) AS INT)                   AS Quantity,
        TRY_CAST(LTRIM(RTRIM([Discount])) AS DECIMAL(5,2))          AS Discount,
        TRY_CAST(LTRIM(RTRIM([Profit])) AS DECIMAL(18,4))           AS Profit
    FROM bronze_latest
    WHERE rn = 1
),

-- Work out the canonical (most-recent-order-date) name per Product ID
canonical_names AS (
    SELECT ProductID, ProductName AS CanonicalProductName
    FROM (
        SELECT
            ProductID,
            ProductName,
            ROW_NUMBER() OVER (
                PARTITION BY ProductID
                ORDER BY OrderDate DESC
            ) AS rn
        FROM cleaned
        WHERE ProductID IS NOT NULL
    ) AS ranked
    WHERE rn = 1
),

-- Flag rows that fail basic business-rule checks:
--   Quantity must be positive, Discount must be a fraction (0 to 1),
--   Sales can't be negative, and a shipment can't leave before it was
--   ordered.
flagged AS (
    SELECT
        c.*,
        cn.CanonicalProductName,
        CASE WHEN c.ProductName <> cn.CanonicalProductName THEN 1 ELSE 0 END AS HasNameMismatch,
        CASE
            WHEN c.Quantity <= 0
              OR c.Discount < 0 OR c.Discount > 1
              OR c.Sales < 0
              OR (c.OrderDate IS NOT NULL AND c.ShipDate IS NOT NULL AND c.ShipDate < c.OrderDate)
              OR c.RowID IS NULL
            THEN 1 ELSE 0
        END AS HasInvalidValue
    FROM cleaned c
    LEFT JOIN canonical_names cn ON cn.ProductID = c.ProductID
)

INSERT INTO silver.sales (
    RowID, OrderID, OrderDate, ShipDate, ShipMode, CustomerID, CustomerName,
    Segment, Country, City, State, PostalCode, Region, ProductID, Category,
    SubCategory, ProductName, CanonicalProductName, Sales, Quantity, Discount,
    Profit, HasInvalidValue, HasNameMismatch
)
SELECT
    RowID, OrderID, OrderDate, ShipDate, ShipMode, CustomerID, CustomerName,
    Segment, Country, City, State, PostalCode, Region, ProductID, Category,
    SubCategory, ProductName, CanonicalProductName, Sales, Quantity, Discount,
    Profit, HasInvalidValue, HasNameMismatch
FROM flagged
WHERE RowID IS NOT NULL;
GO

-- Quick data-quality report: how many rows were flagged, and why.
SELECT
    COUNT(*) AS TotalRows,
    SUM(CAST(HasInvalidValue AS INT)) AS InvalidValueRows,
    SUM(CAST(HasNameMismatch AS INT)) AS NameMismatchRows
FROM silver.sales;
-- Expected on the real dataset: 2,323 total rows, 0 invalid-value rows
-- (this source data turned out to be clean on those specific rules),
-- 22 name-mismatch rows (from the 16 Product IDs with 2 names each).
GO
-- =====================================================================
-- STEP 4: GOLD LAYER -- the star schema

--
--                     dim_customer
--                          |
--   dim_ship_mode ---- fact_sales ---- dim_product
--                          |
--                    dim_location   dim_date
-- =====================================================================
IF OBJECT_ID('gold.fact_sales', 'U') IS NOT NULL DROP TABLE gold.fact_sales;
IF OBJECT_ID('gold.dim_customer', 'U') IS NOT NULL DROP TABLE gold.dim_customer;
IF OBJECT_ID('gold.dim_product', 'U') IS NOT NULL DROP TABLE gold.dim_product;
IF OBJECT_ID('gold.dim_location', 'U') IS NOT NULL DROP TABLE gold.dim_location;
IF OBJECT_ID('gold.dim_ship_mode', 'U') IS NOT NULL DROP TABLE gold.dim_ship_mode;
IF OBJECT_ID('gold.dim_date', 'U') IS NOT NULL DROP TABLE gold.dim_date;
GO

-- ---------------------------------------------------------------------
-- DIMENSION TABLES
-- ---------------------------------------------------------------------

CREATE TABLE gold.dim_customer (
    CustomerKey  INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID   NVARCHAR(255) NOT NULL,
    CustomerName NVARCHAR(255),
    Segment      NVARCHAR(255),
    CONSTRAINT UQ_dim_customer_CustomerID UNIQUE (CustomerID)
);
GO

CREATE TABLE gold.dim_product (
    ProductKey  INT IDENTITY(1,1) PRIMARY KEY,
    ProductID   NVARCHAR(255) NOT NULL,
    Category    NVARCHAR(255),
    SubCategory NVARCHAR(255),
    ProductName NVARCHAR(500),   -- the cleaned, canonical name from silver
    CONSTRAINT UQ_dim_product_ProductID UNIQUE (ProductID)
);
GO

CREATE TABLE gold.dim_location (
    LocationKey INT IDENTITY(1,1) PRIMARY KEY,
    Country     NVARCHAR(255),
    City        NVARCHAR(255),
    State       NVARCHAR(255),
    PostalCode  NVARCHAR(50),
    Region      NVARCHAR(255)
);
GO

CREATE TABLE gold.dim_ship_mode (
    ShipModeKey INT IDENTITY(1,1) PRIMARY KEY,
    ShipMode    NVARCHAR(255) NOT NULL,
    CONSTRAINT UQ_dim_ship_mode UNIQUE (ShipMode)
);
GO

CREATE TABLE gold.dim_date (
    DateKey       INT PRIMARY KEY,   -- format YYYYMMDD, e.g. 20130103
    FullDate      DATE NOT NULL,
    DayNumber     INT,
    MonthNumber   INT,
    MonthName     NVARCHAR(20),
    QuarterNumber INT,
    YearNumber    INT,
    DayName       NVARCHAR(20),
    IsWeekend     BIT
);
GO

-- ---------------------------------------------------------------------
-- FACT TABLE
-- ---------------------------------------------------------------------

CREATE TABLE gold.fact_sales (
    RowID       INT PRIMARY KEY,       
    OrderID     NVARCHAR(255) NOT NULL,
    CustomerKey INT NOT NULL,
    ProductKey  INT NOT NULL,
    LocationKey INT NOT NULL,
    ShipModeKey INT NOT NULL,
    DateKey     INT NOT NULL,
    Sales       DECIMAL(18,4),
    Quantity    INT,
    Discount    DECIMAL(5,2),
    Profit      DECIMAL(18,4),

    CONSTRAINT FK_fact_customer  FOREIGN KEY (CustomerKey) REFERENCES gold.dim_customer(CustomerKey),
    CONSTRAINT FK_fact_product   FOREIGN KEY (ProductKey)  REFERENCES gold.dim_product(ProductKey),
    CONSTRAINT FK_fact_location  FOREIGN KEY (LocationKey) REFERENCES gold.dim_location(LocationKey),
    CONSTRAINT FK_fact_shipmode  FOREIGN KEY (ShipModeKey) REFERENCES gold.dim_ship_mode(ShipModeKey),
    CONSTRAINT FK_fact_date      FOREIGN KEY (DateKey)     REFERENCES gold.dim_date(DateKey)
);
GO

INSERT INTO gold.dim_customer (CustomerID, CustomerName, Segment)
SELECT DISTINCT CustomerID, CustomerName, Segment
FROM silver.sales
WHERE HasInvalidValue = 0 AND CustomerID IS NOT NULL;
GO

INSERT INTO gold.dim_product (ProductID, Category, SubCategory, ProductName)
SELECT DISTINCT ProductID, Category, SubCategory, CanonicalProductName
FROM silver.sales
WHERE HasInvalidValue = 0 AND ProductID IS NOT NULL;
GO

INSERT INTO gold.dim_location (Country, City, State, PostalCode, Region)
SELECT DISTINCT Country, City, State, PostalCode, Region
FROM silver.sales
WHERE HasInvalidValue = 0 AND Country IS NOT NULL;
GO

INSERT INTO gold.dim_ship_mode (ShipMode)
SELECT DISTINCT ShipMode
FROM silver.sales
WHERE HasInvalidValue = 0 AND ShipMode IS NOT NULL;
GO

INSERT INTO gold.dim_date (DateKey, FullDate, DayNumber, MonthNumber, MonthName, QuarterNumber, YearNumber, DayName, IsWeekend)
SELECT DISTINCT
    CONVERT(INT, CONVERT(CHAR(8), OrderDate, 112)) AS DateKey,
    OrderDate,
    DAY(OrderDate),
    MONTH(OrderDate),
    DATENAME(MONTH, OrderDate),
    DATEPART(QUARTER, OrderDate),
    YEAR(OrderDate),
    DATENAME(WEEKDAY, OrderDate),
    CASE WHEN DATEPART(WEEKDAY, OrderDate) IN (1,7) THEN 1 ELSE 0 END
FROM silver.sales
WHERE HasInvalidValue = 0 AND OrderDate IS NOT NULL;
GO

INSERT INTO gold.fact_sales (RowID, OrderID, CustomerKey, ProductKey, LocationKey, ShipModeKey, DateKey, Sales, Quantity, Discount, Profit)
SELECT
    s.RowID,
    s.OrderID,
    c.CustomerKey,
    p.ProductKey,
    l.LocationKey,
    sm.ShipModeKey,
    CONVERT(INT, CONVERT(CHAR(8), s.OrderDate, 112)) AS DateKey,
    s.Sales,
    s.Quantity,
    s.Discount,
    s.Profit
FROM silver.sales s
JOIN gold.dim_customer  c  ON c.CustomerID = s.CustomerID
JOIN gold.dim_product   p  ON p.ProductID  = s.ProductID
JOIN gold.dim_location  l  ON l.Country = s.Country AND l.City = s.City AND l.State = s.State
                           AND l.PostalCode = s.PostalCode AND l.Region = s.Region
JOIN gold.dim_ship_mode sm ON sm.ShipMode = s.ShipMode
WHERE s.HasInvalidValue = 0;
GO

-- Sanity check row counts (expected on the real dataset):
SELECT 'dim_customer' AS TableName, COUNT(*) AS Rows FROM gold.dim_customer   -- 629
UNION ALL SELECT 'dim_product', COUNT(*) FROM gold.dim_product               -- 1,310
UNION ALL SELECT 'dim_location', COUNT(*) FROM gold.dim_location             -- 195
UNION ALL SELECT 'dim_ship_mode', COUNT(*) FROM gold.dim_ship_mode           -- 4
UNION ALL SELECT 'dim_date', COUNT(*) FROM gold.dim_date                     -- 720
UNION ALL SELECT 'fact_sales', COUNT(*) FROM gold.fact_sales;                -- 2,323
GO
-- =====================================================================
-- SQL VIEWS and STORED PROCEDURES for KPI reporting
-- =====================================================================

-- ---------------------------------------------------------------------
-- VIEW 1: Monthly sales KPIs
-- ---------------------------------------------------------------------
IF OBJECT_ID('gold.vw_monthly_sales_kpi', 'V') IS NOT NULL
    DROP VIEW gold.vw_monthly_sales_kpi;
GO

CREATE VIEW gold.vw_monthly_sales_kpi AS
SELECT
    d.YearNumber,
    d.MonthNumber,
    d.MonthName,
    COUNT(DISTINCT f.OrderID)      AS OrderCount,
    SUM(f.Sales)                   AS TotalSales,
    SUM(f.Profit)                  AS TotalProfit,
    SUM(f.Quantity)                AS TotalQuantity,
    AVG(f.Discount)                AS AvgDiscount,
    CASE WHEN SUM(f.Sales) = 0 THEN NULL
         ELSE SUM(f.Profit) / SUM(f.Sales) END AS ProfitMargin
FROM gold.fact_sales f
JOIN gold.dim_date d ON d.DateKey = f.DateKey
GROUP BY d.YearNumber, d.MonthNumber, d.MonthName;
GO

-- Usage:
SELECT * FROM gold.vw_monthly_sales_kpi ORDER BY YearNumber, MonthNumber;

-- ---------------------------------------------------------------------
-- VIEW 2: Customer profitability
-- Supports the "customer behavior" business-analytics requirement.
-- ---------------------------------------------------------------------
IF OBJECT_ID('gold.vw_customer_profitability', 'V') IS NOT NULL
    DROP VIEW gold.vw_customer_profitability;
GO

CREATE VIEW gold.vw_customer_profitability AS
SELECT
    c.CustomerKey,
    c.CustomerName,
    c.Segment,
    COUNT(DISTINCT f.OrderID)   AS OrderCount,
    SUM(f.Sales)                AS TotalSales,
    SUM(f.Profit)               AS TotalProfit,
    CASE WHEN SUM(f.Sales) = 0 THEN NULL
         ELSE SUM(f.Profit) / SUM(f.Sales) END AS ProfitMargin
FROM gold.fact_sales f
JOIN gold.dim_customer c ON c.CustomerKey = f.CustomerKey
GROUP BY c.CustomerKey, c.CustomerName, c.Segment;
GO

-- Usage:
SELECT TOP 10 * FROM gold.vw_customer_profitability ORDER BY TotalProfit DESC;

-- ---------------------------------------------------------------------
-- STORED PROCEDURE 1: sales KPIs for a date range, with prior-period comparison
-- ---------------------------------------------------------------------
IF OBJECT_ID('gold.usp_get_sales_kpis_by_period', 'P') IS NOT NULL
    DROP PROCEDURE gold.usp_get_sales_kpis_by_period;
GO

CREATE PROCEDURE gold.usp_get_sales_kpis_by_period
    @StartDate DATE,
    @EndDate   DATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PeriodDays INT = DATEDIFF(DAY, @StartDate, @EndDate) + 1;
    DECLARE @PriorStart DATE = DATEADD(DAY, -@PeriodDays, @StartDate);
    DECLARE @PriorEnd   DATE = DATEADD(DAY, -1, @StartDate);

    WITH current_period AS (
        SELECT SUM(f.Sales) AS TotalSales, SUM(f.Profit) AS TotalProfit,
               SUM(f.Quantity) AS TotalQuantity, COUNT(DISTINCT f.OrderID) AS OrderCount
        FROM gold.fact_sales f
        JOIN gold.dim_date d ON d.DateKey = f.DateKey
        WHERE d.FullDate BETWEEN @StartDate AND @EndDate
    ),
    prior_period AS (
        SELECT SUM(f.Sales) AS TotalSales, SUM(f.Profit) AS TotalProfit
        FROM gold.fact_sales f
        JOIN gold.dim_date d ON d.DateKey = f.DateKey
        WHERE d.FullDate BETWEEN @PriorStart AND @PriorEnd
    )
    SELECT
        c.TotalSales, c.TotalProfit, c.TotalQuantity, c.OrderCount,
        p.TotalSales  AS PriorPeriodSales,
        CASE WHEN p.TotalSales IS NULL OR p.TotalSales = 0 THEN NULL
             ELSE (c.TotalSales - p.TotalSales) / p.TotalSales * 100
        END AS SalesGrowthPct
    FROM current_period c
    CROSS JOIN prior_period p;
END;
GO

-- Usage:
EXEC gold.usp_get_sales_kpis_by_period @StartDate = '2016-01-01', @EndDate = '2016-12-31';

-- ---------------------------------------------------------------------
-- STORED PROCEDURE 2: top N products by profit, optionally filtered by category.
-- ---------------------------------------------------------------------
IF OBJECT_ID('gold.usp_top_n_products_by_profit', 'P') IS NOT NULL
    DROP PROCEDURE gold.usp_top_n_products_by_profit;
GO

CREATE PROCEDURE gold.usp_top_n_products_by_profit
    @TopN     INT,
    @Category NVARCHAR(255) = NULL   -- optional: NULL means "all categories"
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@TopN)
        p.ProductName,
        p.Category,
        p.SubCategory,
        SUM(f.Profit) AS TotalProfit,
        SUM(f.Sales)  AS TotalSales
    FROM gold.fact_sales f
    JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
    WHERE @Category IS NULL OR p.Category = @Category
    GROUP BY p.ProductName, p.Category, p.SubCategory
    ORDER BY TotalProfit DESC;
END;
GO

-- Usage:
EXEC gold.usp_top_n_products_by_profit @TopN = 5;
EXEC gold.usp_top_n_products_by_profit @TopN = 5, @Category = 'Technology';
-- =====================================================================
-- BUSINESS ANALYTICS QUERIES
-- =====================================================================

-- =====================================================================
                        -- SECTION A: PROFITABILITY
-- =====================================================================

------------------------------------------------------------------------------------
-- Query 1: Total sales, profit, and a CASE-based profitability label per Category
------------------------------------------------------------------------------------
SELECT
    p.Category,
    SUM(f.Sales)  AS TotalSales,
    SUM(f.Profit) AS TotalProfit,
    CASE
        WHEN SUM(f.Profit) < 0 THEN 'Loss-making'
        WHEN SUM(f.Profit) / NULLIF(SUM(f.Sales),0) < 0.10 THEN 'Low margin'
        ELSE 'Healthy margin'
    END AS ProfitHealth
FROM gold.fact_sales f
JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
GROUP BY p.Category
ORDER BY TotalProfit DESC;
-----------------
-- INSIGHT: 
-----------------
-- Technology is the profit engine of the Central region
-- ($33,697 total profit), Office Supplies is solidly profitable
-- ($8,880), but Furniture is a net LOSS (-$2,871) despite generating
-- real sales volume. This is worth flagging to leadership directly --
-- Furniture pricing or discounting practices need review.

----------------------------------------------------------------------
-- Query 2: Which Sub-Categories are dragging profit down the most?
----------------------------------------------------------------------
SELECT TOP 5
    p.SubCategory,
    SUM(f.Profit) AS TotalProfit
FROM gold.fact_sales f
JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
GROUP BY p.SubCategory
ORDER BY TotalProfit ASC;
-----------------
-- INSIGHT: 
-----------------
-- Furnishings (-$3,906) and Tables (-$3,560) are the two
-- biggest loss-making sub-categories in the entire dataset -- both are
-- Furniture sub-categories, confirming the Category-level finding above
-- is concentrated, not spread evenly across Furniture's product lines.

--------------------------------------------------------------
-- Query 3: Segment-level average sale size and total profit.
--------------------------------------------------------------
SELECT
    c.Segment,
    AVG(f.Sales)  AS AvgSalePerTransaction,
    SUM(f.Profit) AS TotalProfit
FROM gold.fact_sales f
JOIN gold.dim_customer c ON c.CustomerKey = f.CustomerKey
GROUP BY c.Segment
ORDER BY TotalProfit DESC;

-----------------
-- INSIGHT: 
-----------------
--Corporate customers have both the highest average sale
-- ($234.76 per line) AND the highest total profit ($18,704) of the
-- three segments, despite Consumer almost certainly having more total
-- transactions -- Corporate is the most valuable segment per order.

-----------------------------------------------------------------------------------------------
-- Query 4: States generating high sales but low (or negative) profit --
-- a classic "revenue isn't the same as health" executive flag. 
-----------------------------------------------------------------------------------------------
SELECT
    l.State,
    SUM(f.Sales)  AS TotalSales,
    SUM(f.Profit) AS TotalProfit
FROM gold.fact_sales f
JOIN gold.dim_location l ON l.LocationKey = f.LocationKey
GROUP BY l.State
HAVING SUM(f.Sales) > 50000 AND SUM(f.Profit) < 5000
ORDER BY TotalSales DESC;

-----------------
-- INSIGHT: 
-----------------
-- Both Texas ($170,188 sales / -$25,729 profit) and Illinois
-- ($80,166 sales / -$12,608 profit) are the region's two biggest
-- revenue states, and BOTH are losing money overall. These two states
-- alone are worth a discounting/cost audit -- they're not just
-- "underperforming," they're actively unprofitable at scale.

-------------------------------------------------------------------------------
-- Query 5: Products that sell above the average total-sales-per-product
-------------------------------------------------------------------------------

SELECT
    p.ProductName,
    SUM(f.Sales) AS TotalSales
FROM gold.fact_sales f
JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
GROUP BY p.ProductName
HAVING SUM(f.Sales) > (
    SELECT AVG(ProductTotal)
    FROM (
        SELECT SUM(f2.Sales) AS ProductTotal
        FROM gold.fact_sales f2
        JOIN gold.dim_product p2 ON p2.ProductKey = f2.ProductKey
        GROUP BY p2.ProductKey
    ) AS PerProductTotals
)
ORDER BY TotalSales DESC;

-------------------------------------------------------------------------------
-- Query 6: Categories whose total profit beats the average category profit.
-------------------------------------------------------------------------------

WITH category_profit AS (
    SELECT p.Category, SUM(f.Profit) AS TotalProfit
    FROM gold.fact_sales f
    JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
    GROUP BY p.Category
)
SELECT Category, TotalProfit
FROM category_profit
WHERE TotalProfit > (SELECT AVG(TotalProfit) FROM category_profit)
ORDER BY TotalProfit DESC;

----------------------------------------------------------------------------------------
-- Query 7: Top 3 products by sales within each category.
----------------------------------------------------------------------------------------

WITH product_sales AS (
    SELECT p.Category, p.ProductName, SUM(f.Sales) AS TotalSales
    FROM gold.fact_sales f
    JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
    GROUP BY p.Category, p.ProductName
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY Category ORDER BY TotalSales DESC) AS SalesRank
    FROM product_sales
)
SELECT Category, ProductName, TotalSales, SalesRank
FROM ranked
WHERE SalesRank <= 3
ORDER BY Category, SalesRank;

----------------------------------------------------------------
-- Query 8: Highest profit-margin product within each category.
----------------------------------------------------------------
WITH product_margin AS (
    SELECT
        p.Category, p.ProductName,
        SUM(f.Profit) AS TotalProfit,
        SUM(f.Sales)  AS TotalSales,
        SUM(f.Profit) / NULLIF(SUM(f.Sales), 0) AS ProfitMargin
    FROM gold.fact_sales f
    JOIN gold.dim_product p ON p.ProductKey = f.ProductKey
    GROUP BY p.Category, p.ProductName
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY Category ORDER BY ProfitMargin DESC) AS MarginRank
    FROM product_margin
)
SELECT Category, ProductName, TotalProfit, TotalSales, ProfitMargin
FROM ranked
WHERE MarginRank = 1
ORDER BY ProfitMargin DESC;

----------------------------------------------------------------------------------
-- Query 9: Discount-band analysis -- what does heavy discounting do to profit?
----------------------------------------------------------------------------------

SELECT
    CASE
        WHEN f.Discount = 0 THEN 'No discount'
        WHEN f.Discount <= 0.20 THEN 'Light (up to 20%)'
        WHEN f.Discount <= 0.50 THEN 'Moderate (21-50%)'
        ELSE 'Heavy (over 50%)'
    END AS DiscountBand,
    COUNT(*) AS LineCount,
    SUM(f.Sales)  AS TotalSales,
    SUM(f.Profit) AS TotalProfit
FROM gold.fact_sales f
GROUP BY
    CASE
        WHEN f.Discount = 0 THEN 'No discount'
        WHEN f.Discount <= 0.20 THEN 'Light (up to 20%)'
        WHEN f.Discount <= 0.50 THEN 'Moderate (21-50%)'
        ELSE 'Heavy (over 50%)'
    END
ORDER BY TotalProfit ASC;

-------------
-- INSIGHT: 
-------------
-- Discount and profit are negatively correlated across the
-- whole dataset (correlation coefficient -0.23). The 456 order lines
-- with a discount of 50% or more collectively lose -$40,793 -- heavy
-- discounting isn't just "lower margin," it's actively destroying
-- profit for that slice of transactions.

-- =====================================================================
                            -- SECTION B: CUSTOMER BEHAVIOR
-- =====================================================================

------------------------------------------------------------------------------
-- Query 10: Segments whose total profit beats the average across segments. 
------------------------------------------------------------------------------

WITH segment_profit AS (
    SELECT c.Segment, SUM(f.Profit) AS TotalProfit
    FROM gold.fact_sales f
    JOIN gold.dim_customer c ON c.CustomerKey = f.CustomerKey
    GROUP BY c.Segment
),
with_avg AS (
    SELECT Segment, TotalProfit, AVG(TotalProfit) OVER () AS AvgAcrossSegments
    FROM segment_profit
)
SELECT * FROM with_avg WHERE TotalProfit > AvgAcrossSegments;

---------------------------------------------------------------------------
-- Query 11: Repeat vs. one-time customers -- who's more valuable?
---------------------------------------------------------------------------

WITH customer_orders AS (
    SELECT
        f.CustomerKey,
        COUNT(DISTINCT f.OrderID) AS OrderCount,
        SUM(f.Sales)  AS TotalSales,
        SUM(f.Profit) AS TotalProfit
    FROM gold.fact_sales f
    GROUP BY f.CustomerKey
)
SELECT
    CASE WHEN OrderCount > 1 THEN 'Repeat customer' ELSE 'One-time customer' END AS CustomerType,
    COUNT(*) AS NumCustomers,
    AVG(TotalSales)  AS AvgSalesPerCustomer,
    AVG(TotalProfit) AS AvgProfitPerCustomer
FROM customer_orders
GROUP BY CASE WHEN OrderCount > 1 THEN 'Repeat customer' ELSE 'One-time customer' END;

-------------
-- INSIGHT: 
-------------
-- 345 of the region's 629 customers (about 55%) have placed
-- more than one order. Given that repeat customers accumulate more
-- transactions to average over, this comparison highlights how much of
-- total profit depends on retention rather than one-off sales --
-- worth checking against acquisition cost data outside this dataset.

-------------------------------------------------------------------------
-- Query 12: Top 10 customers by total profit.
-------------------------------------------------------------------------

SELECT TOP 10 CustomerName, Segment, OrderCount, TotalSales, TotalProfit
FROM gold.vw_customer_profitability
ORDER BY TotalProfit DESC;

-------------
-- INSIGHT: 
-------------
-- By total sales, Tamara Chand ($18,437), Adrian Barton
-- ($12,182), and Becky Martin ($10,540) are the top 3 customers in the
-- Central region -- a small group of high-value accounts worth
-- proactive account management rather than generic marketing.

-----------------------------------------------------------------------------------------------
-- Query 13: Customers whose total sales exceed the OVERALL average sales-per-customer.
-----------------------------------------------------------------------------------------------

SELECT DISTINCT c.CustomerName, c.Segment
FROM gold.dim_customer c
JOIN gold.fact_sales f ON f.CustomerKey = c.CustomerKey
WHERE EXISTS (
    SELECT 1
    FROM gold.fact_sales f2
    WHERE f2.CustomerKey = c.CustomerKey
    GROUP BY f2.CustomerKey
    HAVING SUM(f2.Sales) > (
        SELECT AVG(CustTotal) FROM (
            SELECT SUM(Sales) AS CustTotal FROM gold.fact_sales GROUP BY CustomerKey
        ) AS Totals
    )
);

----------------------------------------------------------------------------
-- Query 14: Ship Mode performance -- does faster shipping cost profit?
----------------------------------------------------------------------------

SELECT
    sm.ShipMode,
    COUNT(*)      AS LineCount,
    AVG(f.Discount) AS AvgDiscount,
    SUM(f.Profit) AS TotalProfit
FROM gold.fact_sales f
JOIN gold.dim_ship_mode sm ON sm.ShipModeKey = f.ShipModeKey
GROUP BY sm.ShipMode
ORDER BY TotalProfit DESC;

-- =====================================================================
                        -- SECTION C: SALES TRENDS
-- =====================================================================

------------------------------------------------------
-- Query 15: Monthly sales KPIs via the view.
------------------------------------------------------

SELECT * FROM gold.vw_monthly_sales_kpi ORDER BY YearNumber, MonthNumber;

-- Query 16: Year-over-year sales and profit growth. (CTE + LAG window function)
WITH yearly AS (
    SELECT d.YearNumber, SUM(f.Sales) AS TotalSales, SUM(f.Profit) AS TotalProfit
    FROM gold.fact_sales f
    JOIN gold.dim_date d ON d.DateKey = f.DateKey
    GROUP BY d.YearNumber
),
with_prior AS (
    SELECT
        YearNumber, TotalSales, TotalProfit,
        LAG(TotalSales) OVER (ORDER BY YearNumber) AS PriorYearSales
    FROM yearly
)
SELECT
    YearNumber, TotalSales, TotalProfit, PriorYearSales,
    CASE WHEN PriorYearSales IS NULL THEN NULL
         ELSE (TotalSales - PriorYearSales) / PriorYearSales * 100
    END AS SalesGrowthPct
FROM with_prior
ORDER BY YearNumber;

--------------
-- INSIGHT: 
--------------
-- Sales grew every year from 2013 ($103,838) to 2015
-- ($147,429), then were essentially flat into 2016 ($147,098). Profit
-- tells a more worrying story: it peaked in 2015 ($19,899) and then
-- DROPPED by more than half in 2016 ($7,551) even though sales held
-- steady -- meaning 2016's flat revenue was achieved at a meaningfully
-- worse margin than 2015's growth year.

-------------------------------------------------------------------------------------
-- Query 17: State-by-state sales, ranked, with the gap to the next- highest state.
-------------------------------------------------------------------------------------

WITH state_sales AS (
    SELECT l.State, SUM(f.Sales) AS TotalSales
    FROM gold.fact_sales f
    JOIN gold.dim_location l ON l.LocationKey = f.LocationKey
    GROUP BY l.State
)
SELECT
    State, TotalSales,
    LAG(TotalSales) OVER (ORDER BY TotalSales DESC) AS NextHighestState,
    TotalSales - LAG(TotalSales) OVER (ORDER BY TotalSales DESC) AS GapToNextHighest
FROM state_sales
ORDER BY TotalSales DESC;

-------------
-- INSIGHT: 
-------------
-- Texas ($170,188) leads by a wide margin -- more than double
-- Illinois, the #2 state ($80,166). Sales concentration is high: the
-- top 2 states alone account for roughly a third of all Central-region
-- sales, so regional strategy is disproportionately a Texas story.

-----------------------------------------------------------
-- Query 18: Quarterly sales trend within each year. 
-----------------------------------------------------------

WITH quarterly AS (
    SELECT d.YearNumber, d.QuarterNumber, SUM(f.Sales) AS TotalSales, SUM(f.Profit) AS TotalProfit
    FROM gold.fact_sales f
    JOIN gold.dim_date d ON d.DateKey = f.DateKey
    GROUP BY d.YearNumber, d.QuarterNumber
)
SELECT * FROM quarterly ORDER BY YearNumber, QuarterNumber;
