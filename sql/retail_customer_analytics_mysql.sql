-- =============================================================================
-- Retail Customer Analytics | SQL layer
-- Dialect : MySQL 8.0+ (needs window functions, CTEs and REGEXP_REPLACE)
-- Layers  : raw table -> cleaning view -> analysis queries -> RFM view -> segments
-- Notes   : * Money is INR. Run sections top to bottom; each is re-runnable.
--           * Cleaning follows the main Python validation rules.
--           * Repeated transaction IDs are deduplicated by keeping the first row_id.
--           * Python separately tracks exact duplicate rows in its audit.
-- =============================================================================


-- =============================================================================
-- 0. DATABASE, RAW TABLE & HELPER FUNCTION
-- =============================================================================
CREATE DATABASE IF NOT EXISTS retail;
USE retail;

CREATE TABLE IF NOT EXISTS transactions_raw (
    row_id            BIGINT NOT NULL AUTO_INCREMENT,   -- load order = file order
    customer_id       VARCHAR(20),
    gender            VARCHAR(20),
    age               DECIMAL(5, 1),
    city              VARCHAR(60),
    transaction_id    VARCHAR(20),
    transaction_date  DATE,
    product_category  VARCHAR(60),
    quantity          INT,
    price             DECIMAL(12, 2),
    total_amount      DECIMAL(14, 2),
    PRIMARY KEY (row_id),
    -- Supports customer-level aggregation and date-range scans on the raw layer
    KEY ix_txn_raw_customer_date (customer_id, transaction_date),
    KEY ix_txn_raw_txn_id (transaction_id)
);

-- Load example (CSV with a header row and dates like 16-Dec-2024).
-- If you get "Loading local data is disabled", run:  SET GLOBAL local_infile = 1;
-- and connect with local infile enabled (Workbench: Advanced > OPT_LOCAL_INFILE=1).
-- You can also use Workbench: right-click the table > Table Data Import Wizard.
--
-- LOAD DATA LOCAL INFILE 'data/Retail_Customer_Dataset.csv'
-- INTO TABLE transactions_raw
-- FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 LINES
-- (customer_id, gender, @age, city, transaction_id, @txn_date, product_category,
--  @qty, @price, @total)
-- SET age              = NULLIF(@age, ''),
--     transaction_date = STR_TO_DATE(NULLIF(@txn_date, ''), '%d-%b-%Y'),
--     quantity         = NULLIF(@qty, ''),
--     price            = NULLIF(@price, ''),
--     total_amount     = NULLIF(@total, '');

-- title_case('home &  kitchen') -> 'Home & Kitchen'  (same as Python str.title())
DROP FUNCTION IF EXISTS title_case;
DELIMITER $$
CREATE FUNCTION title_case(s VARCHAR(255)) RETURNS VARCHAR(255) DETERMINISTIC
BEGIN
    DECLARE i    INT DEFAULT 1;
    DECLARE n    INT;
    DECLARE ch   VARCHAR(1);              -- VARCHAR, not CHAR: CHAR would drop a space
    DECLARE prev VARCHAR(1) DEFAULT ' ';
    DECLARE res  VARCHAR(255) DEFAULT '';
    IF s IS NULL THEN
        RETURN NULL;
    END IF;
    SET n = CHAR_LENGTH(s);
    WHILE i <= n DO
        SET ch = SUBSTRING(s, i, 1);
        IF prev REGEXP '^[A-Za-z]$' THEN
            SET res = CONCAT(res, LOWER(ch));
        ELSE
            SET res = CONCAT(res, UPPER(ch));
        END IF;
        SET prev = ch;
        SET i = i + 1;
    END WHILE;
    RETURN res;
END$$
DELIMITER ;


-- =============================================================================
-- 1. CLEANING VIEW  (mirrors the Python cleaning rules, in the same order)
--    * trims, collapses spaces and title-cases text; upper-cases IDs
--    * blank or missing Gender / City / ProductCategory -> 'Unknown'  (as in Python)
--    * removes null keys and dates after the observation window
--    * removes repeated transaction IDs, keeping the FIRST row in file order (row_id)
--    * THEN removes invalid quantity / price (same order as Python)
--    * out-of-range age -> median of the remaining valid ages
--    * total_amount recomputed as quantity x price when null or off by > INR 0.01
-- =============================================================================
CREATE OR REPLACE VIEW vw_transactions_clean AS
WITH normalised AS (
    SELECT
        row_id,
        UPPER(TRIM(customer_id))                              AS customer_id,
        COALESCE(
            CASE UPPER(NULLIF(TRIM(REGEXP_REPLACE(gender, '\\s+', ' ')), ''))
                 WHEN 'M' THEN 'Male'
                 WHEN 'F' THEN 'Female'
                 ELSE title_case(NULLIF(TRIM(REGEXP_REPLACE(gender, '\\s+', ' ')), ''))
            END, 'Unknown')                                   AS gender,
        CASE WHEN age BETWEEN 18 AND 90 THEN age END          AS age,
        COALESCE(title_case(NULLIF(TRIM(REGEXP_REPLACE(city, '\\s+', ' ')), '')),
                 'Unknown')                                   AS city,
        UPPER(TRIM(transaction_id))                           AS transaction_id,
        transaction_date,
        COALESCE(title_case(NULLIF(TRIM(REGEXP_REPLACE(product_category, '\\s+', ' ')), '')),
                 'Unknown')                                   AS product_category,
        quantity,
        price,
        total_amount
    FROM transactions_raw
    WHERE customer_id      IS NOT NULL
      AND transaction_id   IS NOT NULL
      AND transaction_date IS NOT NULL
      AND transaction_date <= DATE '2024-12-31'   -- end of observation window; later dates are invalid
),
deduplicated AS (
    SELECT n.*,
           ROW_NUMBER() OVER (PARTITION BY n.transaction_id ORDER BY n.row_id) AS rn
    FROM normalised AS n
),
valid AS (
    SELECT *
    FROM deduplicated
    WHERE rn = 1
      AND quantity >= 1
      AND price    >  0
),
age_sorted AS (
    SELECT age,
           ROW_NUMBER() OVER (ORDER BY age) AS rn,
           COUNT(*) OVER ()                 AS n
    FROM valid
    WHERE age IS NOT NULL
),
age_stats AS (                                   -- median = average of the middle row(s)
    SELECT AVG(age) AS median_age
    FROM age_sorted
    WHERE rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2))
)
SELECT
    v.customer_id,
    v.gender,
    COALESCE(v.age, a.median_age)                             AS age,
    v.city,
    v.transaction_id,
    v.transaction_date,
    v.product_category,
    v.quantity,
    v.price,
    CASE
        WHEN v.total_amount IS NULL
          OR ABS(v.total_amount - v.quantity * v.price) > 0.01
        THEN ROUND(v.quantity * v.price, 2)
        ELSE v.total_amount
    END                                                       AS total_amount
FROM valid AS v
CROSS JOIN age_stats AS a;


-- =============================================================================
-- 2. DATA-QUALITY AUDIT (raw-layer summary; duplicate counts differ from Python's staged audit)
-- =============================================================================
SELECT
    COUNT(*)                                                       AS raw_rows,
    COUNT(*) - COUNT(DISTINCT transaction_id)                      AS duplicate_transaction_ids,
    SUM(age IS NULL)                                               AS null_age,
    SUM(age IS NOT NULL AND age NOT BETWEEN 18 AND 90)             AS out_of_range_age,
    SUM(total_amount IS NULL)                                      AS null_total_amount,
    SUM(total_amount IS NOT NULL
        AND ABS(total_amount - quantity * price) > 0.01)           AS total_amount_mismatch,
    SUM(quantity < 1 OR price <= 0)                                AS invalid_qty_or_price,
    SUM(transaction_date > DATE '2024-12-31')                      AS dates_after_window,
    (SELECT COUNT(*) FROM vw_transactions_clean)                   AS clean_rows
FROM transactions_raw;


-- =============================================================================
-- 3. HEADLINE KPIs
-- =============================================================================
SELECT
    COUNT(*)                                  AS transactions,
    COUNT(DISTINCT customer_id)               AS unique_customers,
    ROUND(SUM(total_amount), 2)               AS total_revenue_inr,
    ROUND(SUM(total_amount) / 1e7, 2)         AS total_revenue_crore,
    ROUND(AVG(total_amount), 2)               AS avg_order_value,
    ROUND(AVG(age), 1)                        AS avg_age,
    MIN(transaction_date)                     AS first_txn_date,
    MAX(transaction_date)                     AS last_txn_date
FROM vw_transactions_clean;


-- =============================================================================
-- 4. REVENUE BY CITY  (rank, share of total, cumulative share)
-- =============================================================================
WITH city_revenue AS (
    SELECT city,
           COUNT(*)          AS transactions,
           SUM(total_amount) AS revenue
    FROM vw_transactions_clean
    GROUP BY city
)
SELECT
    RANK() OVER (ORDER BY revenue DESC)                                  AS revenue_rank,
    city,
    transactions,
    ROUND(revenue, 2)                                                    AS revenue,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)                     AS revenue_share_pct,
    ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC, city
                                     ROWS BETWEEN UNBOUNDED PRECEDING
                                              AND CURRENT ROW)
                / SUM(revenue) OVER (), 2)                               AS cumulative_share_pct
FROM city_revenue
ORDER BY revenue_rank, city;


-- =============================================================================
-- 5. REVENUE vs UNITS BY PRODUCT CATEGORY
-- =============================================================================
WITH category_stats AS (
    SELECT product_category,
           SUM(quantity)     AS units_sold,
           SUM(total_amount) AS revenue
    FROM vw_transactions_clean
    GROUP BY product_category
)
SELECT
    product_category,
    units_sold,
    ROUND(revenue, 2)                                  AS revenue,
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 2)   AS revenue_share_pct,
    RANK() OVER (ORDER BY revenue DESC)                AS revenue_rank,
    RANK() OVER (ORDER BY units_sold DESC)             AS units_rank
FROM category_stats
ORDER BY revenue_rank;


-- =============================================================================
-- 6. MONTHLY REVENUE TREND  (MoM growth + 3-month moving average)
-- =============================================================================
WITH monthly AS (
    SELECT DATE_SUB(transaction_date,
                    INTERVAL DAYOFMONTH(transaction_date) - 1 DAY) AS month_start,
           SUM(total_amount)                                       AS revenue
    FROM vw_transactions_clean
    GROUP BY month_start
)
SELECT
    month_start,
    ROUND(revenue, 2)                                                       AS revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER w)
                / NULLIF(LAG(revenue) OVER w, 0), 2)                        AS mom_growth_pct,
    ROUND(AVG(revenue) OVER (ORDER BY month_start
                             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)  AS revenue_3m_moving_avg
FROM monthly
WINDOW w AS (ORDER BY month_start)
ORDER BY month_start;


-- =============================================================================
-- 7. REVENUE BY AGE GROUP AND GENDER  (same bands as the Power BI AgeGroup column)
-- =============================================================================
SELECT
    CASE
        WHEN age <= 25 THEN '18-25'
        WHEN age <= 35 THEN '26-35'
        WHEN age <= 45 THEN '36-45'
        WHEN age <= 55 THEN '46-55'
        ELSE '56+'
    END                                                           AS age_group,
    gender,
    COUNT(*)                                                      AS transactions,
    ROUND(SUM(total_amount), 2)                                   AS revenue,
    ROUND(100.0 * SUM(total_amount)
                / SUM(SUM(total_amount)) OVER (), 2)              AS revenue_share_pct
FROM vw_transactions_clean
GROUP BY 1, 2
ORDER BY 1, 2;


-- =============================================================================
-- 8. RFM VIEW  (one row per customer; quartile scores built to match pandas)
--    Snapshot date = last valid transaction date + 1 day (same as the Python pipeline)
--    R: recent = 4   F: frequent = 4   M: high spend = 4
--    Python scores with pd.qcut on the values, which keeps tied values in the same bucket,
--    and falls back to rank(method='first') when the quartile edges are not unique
--    (always true for Frequency). This view reproduces both steps:
--    * the quartile edges use pandas' linear interpolation (MySQL has no PERCENTILE_CONT,
--      so they are calculated from ROW_NUMBER: value_lo + fraction * (value_hi - value_lo))
--    * ROW_NUMBER with a customer_id tie-break gives rank(method='first')
-- =============================================================================
CREATE OR REPLACE VIEW vw_rfm_analysis AS
WITH snap AS (
    SELECT DATE_ADD(MAX(transaction_date), INTERVAL 1 DAY) AS snapshot_date
    FROM vw_transactions_clean
),
customer_metrics AS (
    SELECT
        t.customer_id,
        DATEDIFF(s.snapshot_date, MAX(t.transaction_date)) AS recency,
        COUNT(DISTINCT t.transaction_id)                   AS frequency,
        ROUND(SUM(t.total_amount), 2)                      AS monetary
    FROM vw_transactions_clean AS t
    CROSS JOIN snap AS s
    GROUP BY t.customer_id, s.snapshot_date
),
ranked AS (
    SELECT customer_id, recency, frequency, monetary,
           ROW_NUMBER() OVER (ORDER BY recency,   customer_id) AS recency_rank,
           ROW_NUMBER() OVER (ORDER BY frequency, customer_id) AS frequency_rank,
           ROW_NUMBER() OVER (ORDER BY monetary,  customer_id) AS monetary_rank
    FROM customer_metrics
),
r_sorted AS (
    SELECT recency AS v,
           ROW_NUMBER() OVER (ORDER BY recency) AS rn,
           COUNT(*) OVER ()                 AS n
    FROM customer_metrics
),
r_pick AS (
    SELECT
        MAX(n) AS n,
        MIN(v) AS vmin,
        MAX(v) AS vmax,
        MAX(CASE WHEN rn = FLOOR(1 + 0.25 * (n - 1)) THEN v END) AS lo1,
        MAX(CASE WHEN rn = CEIL(1 + 0.25 * (n - 1))  THEN v END) AS hi1,
        MAX(CASE WHEN rn = FLOOR(1 + 0.50 * (n - 1)) THEN v END) AS lo2,
        MAX(CASE WHEN rn = CEIL(1 + 0.50 * (n - 1))  THEN v END) AS hi2,
        MAX(CASE WHEN rn = FLOOR(1 + 0.75 * (n - 1)) THEN v END) AS lo3,
        MAX(CASE WHEN rn = CEIL(1 + 0.75 * (n - 1))  THEN v END) AS hi3
    FROM r_sorted
),
r_edges AS (
    SELECT
        n,
        vmin AS r_min,
        vmax AS r_max,
        CAST(lo1 AS DOUBLE) + ((n - 1) * 0.25 - FLOOR((n - 1) * 0.25)) * (CAST(hi1 AS DOUBLE) - CAST(lo1 AS DOUBLE)) AS r_q1,
        CAST(lo2 AS DOUBLE) + ((n - 1) * 0.50 - FLOOR((n - 1) * 0.50)) * (CAST(hi2 AS DOUBLE) - CAST(lo2 AS DOUBLE)) AS r_q2,
        CAST(lo3 AS DOUBLE) + ((n - 1) * 0.75 - FLOOR((n - 1) * 0.75)) * (CAST(hi3 AS DOUBLE) - CAST(lo3 AS DOUBLE)) AS r_q3
    FROM r_pick
),
f_sorted AS (
    SELECT frequency AS v,
           ROW_NUMBER() OVER (ORDER BY frequency) AS rn,
           COUNT(*) OVER ()                 AS n
    FROM customer_metrics
),
f_pick AS (
    SELECT
        MAX(n) AS n,
        MIN(v) AS vmin,
        MAX(v) AS vmax,
        MAX(CASE WHEN rn = FLOOR(1 + 0.25 * (n - 1)) THEN v END) AS lo1,
        MAX(CASE WHEN rn = CEIL(1 + 0.25 * (n - 1))  THEN v END) AS hi1,
        MAX(CASE WHEN rn = FLOOR(1 + 0.50 * (n - 1)) THEN v END) AS lo2,
        MAX(CASE WHEN rn = CEIL(1 + 0.50 * (n - 1))  THEN v END) AS hi2,
        MAX(CASE WHEN rn = FLOOR(1 + 0.75 * (n - 1)) THEN v END) AS lo3,
        MAX(CASE WHEN rn = CEIL(1 + 0.75 * (n - 1))  THEN v END) AS hi3
    FROM f_sorted
),
f_edges AS (
    SELECT
        n,
        vmin AS f_min,
        vmax AS f_max,
        CAST(lo1 AS DOUBLE) + ((n - 1) * 0.25 - FLOOR((n - 1) * 0.25)) * (CAST(hi1 AS DOUBLE) - CAST(lo1 AS DOUBLE)) AS f_q1,
        CAST(lo2 AS DOUBLE) + ((n - 1) * 0.50 - FLOOR((n - 1) * 0.50)) * (CAST(hi2 AS DOUBLE) - CAST(lo2 AS DOUBLE)) AS f_q2,
        CAST(lo3 AS DOUBLE) + ((n - 1) * 0.75 - FLOOR((n - 1) * 0.75)) * (CAST(hi3 AS DOUBLE) - CAST(lo3 AS DOUBLE)) AS f_q3
    FROM f_pick
),
m_sorted AS (
    SELECT monetary AS v,
           ROW_NUMBER() OVER (ORDER BY monetary) AS rn,
           COUNT(*) OVER ()                 AS n
    FROM customer_metrics
),
m_pick AS (
    SELECT
        MAX(n) AS n,
        MIN(v) AS vmin,
        MAX(v) AS vmax,
        MAX(CASE WHEN rn = FLOOR(1 + 0.25 * (n - 1)) THEN v END) AS lo1,
        MAX(CASE WHEN rn = CEIL(1 + 0.25 * (n - 1))  THEN v END) AS hi1,
        MAX(CASE WHEN rn = FLOOR(1 + 0.50 * (n - 1)) THEN v END) AS lo2,
        MAX(CASE WHEN rn = CEIL(1 + 0.50 * (n - 1))  THEN v END) AS hi2,
        MAX(CASE WHEN rn = FLOOR(1 + 0.75 * (n - 1)) THEN v END) AS lo3,
        MAX(CASE WHEN rn = CEIL(1 + 0.75 * (n - 1))  THEN v END) AS hi3
    FROM m_sorted
),
m_edges AS (
    SELECT
        n,
        vmin AS m_min,
        vmax AS m_max,
        CAST(lo1 AS DOUBLE) + ((n - 1) * 0.25 - FLOOR((n - 1) * 0.25)) * (CAST(hi1 AS DOUBLE) - CAST(lo1 AS DOUBLE)) AS m_q1,
        CAST(lo2 AS DOUBLE) + ((n - 1) * 0.50 - FLOOR((n - 1) * 0.50)) * (CAST(hi2 AS DOUBLE) - CAST(lo2 AS DOUBLE)) AS m_q2,
        CAST(lo3 AS DOUBLE) + ((n - 1) * 0.75 - FLOOR((n - 1) * 0.75)) * (CAST(hi3 AS DOUBLE) - CAST(lo3 AS DOUBLE)) AS m_q3
    FROM m_pick
),
scored AS (
    SELECT
        b.customer_id, b.recency, b.frequency, b.monetary,
        CASE WHEN (r.r_min < r.r_q1 AND r.r_q1 < r.r_q2 AND r.r_q2 < r.r_q3 AND r.r_q3 < r.r_max)
             THEN CASE WHEN b.recency <= r.r_q1 THEN 4 WHEN b.recency <= r.r_q2 THEN 3
                       WHEN b.recency <= r.r_q3 THEN 2 ELSE 1 END
             ELSE CASE WHEN b.recency_rank <= 1 + 0.25 * (r.n - 1) THEN 4
                       WHEN b.recency_rank <= 1 + 0.50 * (r.n - 1) THEN 3
                       WHEN b.recency_rank <= 1 + 0.75 * (r.n - 1) THEN 2 ELSE 1 END
        END AS r_score,
        CASE WHEN (f.f_min < f.f_q1 AND f.f_q1 < f.f_q2 AND f.f_q2 < f.f_q3 AND f.f_q3 < f.f_max)
             THEN CASE WHEN b.frequency <= f.f_q1 THEN 1 WHEN b.frequency <= f.f_q2 THEN 2
                       WHEN b.frequency <= f.f_q3 THEN 3 ELSE 4 END
             ELSE CASE WHEN b.frequency_rank <= 1 + 0.25 * (r.n - 1) THEN 1
                       WHEN b.frequency_rank <= 1 + 0.50 * (r.n - 1) THEN 2
                       WHEN b.frequency_rank <= 1 + 0.75 * (r.n - 1) THEN 3 ELSE 4 END
        END AS f_score,
        CASE WHEN (m.m_min < m.m_q1 AND m.m_q1 < m.m_q2 AND m.m_q2 < m.m_q3 AND m.m_q3 < m.m_max)
             THEN CASE WHEN b.monetary <= m.m_q1 THEN 1 WHEN b.monetary <= m.m_q2 THEN 2
                       WHEN b.monetary <= m.m_q3 THEN 3 ELSE 4 END
             ELSE CASE WHEN b.monetary_rank <= 1 + 0.25 * (r.n - 1) THEN 1
                       WHEN b.monetary_rank <= 1 + 0.50 * (r.n - 1) THEN 2
                       WHEN b.monetary_rank <= 1 + 0.75 * (r.n - 1) THEN 3 ELSE 4 END
        END AS m_score
    FROM ranked AS b
    CROSS JOIN r_edges AS r
    CROSS JOIN f_edges AS f
    CROSS JOIN m_edges AS m
)
SELECT
    customer_id,
    recency,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    r_score + f_score + m_score AS rfm_score,
    CASE
        WHEN r_score + f_score + m_score >= 10 THEN 'High Value Customer'
        WHEN r_score + f_score + m_score >=  7 THEN 'Medium Value Customer'
        ELSE 'Low Value Customer'
    END                         AS segment
FROM scored;


-- =============================================================================
-- 9. SEGMENT SUMMARY  (customers, revenue share, average R/F/M)
-- =============================================================================
SELECT
    segment,
    COUNT(*)                                                    AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS customer_share_pct,
    ROUND(SUM(monetary), 2)                                     AS revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS revenue_share_pct,
    ROUND(AVG(recency), 1)                                      AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                    AS avg_frequency,
    ROUND(AVG(monetary), 2)                                     AS avg_monetary
FROM vw_rfm_analysis
GROUP BY segment
ORDER BY revenue DESC;


-- =============================================================================
-- 10. TOP 100 CUSTOMERS BY LIFETIME SPEND
-- =============================================================================
SELECT
    ROW_NUMBER() OVER (ORDER BY monetary DESC, customer_id) AS spend_rank,
    customer_id, recency, frequency, monetary, rfm_score, segment
FROM vw_rfm_analysis
ORDER BY spend_rank
LIMIT 100;


-- =============================================================================
-- 11. HIGH-VALUE CUSTOMERS AT RISK  (high RFM score but not bought recently)
--     R score <= 2 means the customer sits in the less-recent half of the base.
--     Feed this list to retention campaigns.
-- =============================================================================
SELECT customer_id, recency, frequency, monetary, rfm_score
FROM vw_rfm_analysis
WHERE segment = 'High Value Customer'
  AND r_score <= 2
ORDER BY monetary DESC;


-- =============================================================================
-- 12. PREFERRED CATEGORY OF EACH HIGH-VALUE CUSTOMER  (ROW_NUMBER per customer)
-- =============================================================================
WITH customer_category AS (
    SELECT
        t.customer_id,
        t.product_category,
        SUM(t.total_amount) AS category_spend,
        ROW_NUMBER() OVER (
            PARTITION BY t.customer_id
            ORDER BY SUM(t.total_amount) DESC, t.product_category
        ) AS rn
    FROM vw_transactions_clean AS t
    JOIN vw_rfm_analysis       AS r
      ON r.customer_id = t.customer_id
     AND r.segment     = 'High Value Customer'
    GROUP BY t.customer_id, t.product_category
)
SELECT product_category        AS preferred_category,
       COUNT(*)                AS high_value_customers,
       ROUND(SUM(category_spend), 2) AS spend_in_preferred_category
FROM customer_category
WHERE rn = 1
GROUP BY product_category
ORDER BY high_value_customers DESC;
