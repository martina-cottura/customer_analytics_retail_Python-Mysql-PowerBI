USE customer_analytics;
-- 1. ¿ cuántas plazas utiliza cada cliente?
SELECT
    tiendas_distintas,
    COUNT(*)                                         AS clientes,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM (
    SELECT customer_id, COUNT(DISTINCT store_id) AS tiendas_distintas
    FROM transacciones
    GROUP BY customer_id
) x
GROUP BY tiendas_distintas
ORDER BY tiendas_distintas;

-- ¿ cuánto conserva cada cliente en su plaza principal?

WITH gasto AS (
    SELECT customer_id, store_id, SUM(importe) AS gasto_tienda
    FROM transacciones
    GROUP BY customer_id, store_id
),
ranking AS (
    SELECT
        customer_id,
        gasto_tienda,
        SUM(gasto_tienda) OVER (PARTITION BY customer_id) AS gasto_total,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY gasto_tienda DESC) AS rn
    FROM gasto
)
SELECT
    ROUND(AVG(100 * gasto_tienda / gasto_total), 1) AS pct_medio_plaza_principal,
    ROUND(MIN(100 * gasto_tienda / gasto_total), 1) AS pct_min,
    ROUND(MAX(100 * gasto_tienda / gasto_total), 1) AS pct_max,
    SUM(CASE WHEN gasto_tienda / gasto_total >= 0.7 THEN 1 ELSE 0 END) AS clientes_concentrados_70
FROM ranking
WHERE rn = 1 AND gasto_total > 0;


WITH gasto AS (
    SELECT customer_id, store_id,
           SUM(importe) AS gasto_tienda,
           COUNT(*)     AS compras_tienda
    FROM transacciones
    GROUP BY customer_id, store_id
),
tot AS (
    SELECT customer_id,
           SUM(gasto_tienda)   AS gasto_total,
           SUM(compras_tienda) AS compras_total
    FROM gasto
    GROUP BY customer_id
),
rk AS (
    SELECT g.customer_id, g.compras_tienda, g.gasto_tienda,
           t.compras_total, t.gasto_total,
           ROW_NUMBER() OVER (PARTITION BY g.customer_id
                              ORDER BY g.compras_tienda DESC) AS rn
    FROM gasto g
    JOIN tot t ON t.customer_id = g.customer_id
)
SELECT
    CASE WHEN compras_total <= 2  THEN 'a. 1-2'
         WHEN compras_total <= 5  THEN 'b. 3-5'
         WHEN compras_total <= 10 THEN 'c. 6-10'
         WHEN compras_total <= 20 THEN 'd. 11-20'
         ELSE                          'e. 21+' END        AS banda,
    COUNT(*)                                               AS clientes,
    ROUND(AVG(100 * compras_tienda / compras_total), 1)    AS pct_medio,
    SUM(CASE WHEN compras_tienda / compras_total >= 0.5
             THEN 1 ELSE 0 END)                            AS con_50_o_mas
FROM rk
WHERE rn = 1
GROUP BY banda
ORDER BY banda;