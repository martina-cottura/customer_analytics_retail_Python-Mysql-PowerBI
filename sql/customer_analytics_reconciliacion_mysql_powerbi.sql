-- =====================================================================
-- Cumbres Outdoor & Deporte · base: customer_analytics · MySQL 9.4
-- RECONCILIACIÓN MySQL <-> modelo semántico de Power BI
--
-- Cada consulta reproduce sobre la fuente relacional un indicador
-- expuesto por el modelo semántico. El resultado esperado figura como
-- comentario al pie de cada una y se corresponde con el anexo C del
-- informe técnico.
--
-- Un modelo semántico puede producir cifras plausibles y equivocadas por
-- relaciones mal orientadas, contextos de filtro no previstos o
-- granularidades incompatibles, y esos errores no se manifiestan como
-- fallos sino como números que parecen razonables. Recalcular cada
-- indicador por una vía independiente es la única forma de descartarlos.
--
-- Orden de ejecución del proyecto:
--   1. customer_analytics.sql      esquema, carga y tablas finales
--   2. views_customer_analytics.sql capa de vistas y validación
--   3. este archivo                 reconciliación contra Power BI
--
-- Numeración B.2.n = apartado B.2 del informe técnico.
-- =====================================================================

USE customer_analytics;

-- ---------------------------------------------------------------------
-- B.2.1 Indicadores comerciales globales. Medidas: Revenue Total, Total
-- Transacciones, Total Clientes, Ticket Medio, Frecuencia Compra.
-- ---------------------------------------------------------------------
SELECT
    ROUND(SUM(importe), 2)                           AS revenue_total,
    COUNT(*)                                         AS total_transacciones,
    COUNT(DISTINCT customer_id)                      AS clientes_compradores,
    ROUND(SUM(importe) / COUNT(*), 2)                AS ticket_medio,
    ROUND(COUNT(*) / COUNT(DISTINCT customer_id), 2) AS frecuencia_compra
FROM transacciones;

-- Esperado: 1636931.76 | 7999 | 902 | 204.64 | 8.87

-- ---------------------------------------------------------------------
-- B.2.2 Serie anual y crecimiento interanual. Medida: Crecimiento 2025
-- vs 2024.
-- ---------------------------------------------------------------------
SELECT
    YEAR(fecha)                       AS anio,
    ROUND(SUM(importe), 2)            AS revenue,
    COUNT(*)                          AS transacciones,
    COUNT(DISTINCT customer_id)       AS clientes,
    ROUND(SUM(importe) / COUNT(*), 2) AS ticket_medio
FROM transacciones
GROUP BY YEAR(fecha)
ORDER BY anio;

SELECT ROUND(
    ( SUM(CASE WHEN YEAR(fecha) = 2025 THEN importe ELSE 0 END)
    - SUM(CASE WHEN YEAR(fecha) = 2024 THEN importe ELSE 0 END) )
    / SUM(CASE WHEN YEAR(fecha) = 2024 THEN importe ELSE 0 END) * 100
, 2) AS crecimiento_2025_vs_2024_pct
FROM transacciones;

-- Esperado: 2023 540936.27 / 2661 / 743 - 2024 558092.70 / 2714 / 750 -
-- 2025 537902.79 / 2624 / 730. Crecimiento: -3.62

-- ---------------------------------------------------------------------
-- B.2.3 Distribución por segmento RFM. Medidas: Clientes Segmento, %
-- Clientes Segmento, LTV Medio, Recencia Promedio, Frecuencia Promedio.
-- ---------------------------------------------------------------------
SELECT
    segmento_rfm,
    COUNT(*)                                         AS clientes,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_clientes,
    ROUND(AVG(monetario), 2)                         AS ltv_medio,
    ROUND(AVG(recencia), 1)                          AS recencia_media,
    ROUND(AVG(frecuencia), 2)                        AS frecuencia_media
FROM clientes_rfm
WHERE recencia <> 999
GROUP BY segmento_rfm
ORDER BY ltv_medio DESC;

-- Esperado: Alto 149 / 16.52 / 4583.88 / 30.6 / 22.38 - Medio 266 /
-- 29.49 / 2127.98 / 74.2 / 10.33 - Bajo 487 / 53.99 / 796.49 / 341.5 /
-- 3.93

-- ---------------------------------------------------------------------
-- B.2.4 Participación de cada segmento en la facturación. Medida: %
-- Revenue Segmento. Se calcula desde la tabla de hechos y no desde
-- clientes_rfm.monetario, para verificar que ambas fuentes coinciden.
-- ---------------------------------------------------------------------
SELECT
    r.segmento_rfm,
    ROUND(SUM(t.importe), 2)                                     AS revenue,
    ROUND(100 * SUM(t.importe) / SUM(SUM(t.importe)) OVER (), 2) AS pct_revenue
FROM transacciones t
JOIN clientes_rfm r ON r.customer_id = t.customer_id
GROUP BY r.segmento_rfm
ORDER BY revenue DESC;

-- Esperado: Alto 682998.64 / 41.72 - Medio 566041.81 / 34.58 - Bajo
-- 387891.31 / 23.70

-- ---------------------------------------------------------------------
-- B.2.5 Clientes en riesgo y activos. Medidas: % Clientes en Riesgo, % Clientes
-- Activos, Clientes Activos, Clientes Inactivos (En Riesgo), Usuarios Sin
-- Transacciones. % Clientes Activos es la proporción de compradores con
-- recencia dentro del umbral; no es una tasa de retención entre períodos.
-- ---------------------------------------------------------------------
SELECT
    SUM(CASE WHEN en_riesgo = 0 AND recencia <> 999 THEN 1 ELSE 0 END) AS clientes_activos,
    SUM(CASE WHEN en_riesgo = 1                     THEN 1 ELSE 0 END) AS clientes_en_riesgo,
    SUM(CASE WHEN recencia  = 999                     THEN 1 ELSE 0 END) AS sin_transacciones,
    ROUND(100 * SUM(CASE WHEN en_riesgo = 1 THEN 1 ELSE 0 END)
              / SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END), 2)     AS pct_en_riesgo,
    ROUND(100 * SUM(CASE WHEN en_riesgo = 0 AND recencia <> 999 THEN 1 ELSE 0 END)
              / SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END), 2)     AS pct_activos
FROM clientes_rfm;

-- Esperado: 631 | 271 | 98 | 30.04 | 69.96

-- ---------------------------------------------------------------------
-- B.2.6 Clientes en riesgo por segmento. Verifica la distribución 0% / 0% / 55,65%
-- del apartado 7.3.
-- ---------------------------------------------------------------------
SELECT
    segmento_rfm,
    COUNT(*)                                     AS clientes,
    SUM(en_riesgo)                            AS en_riesgo,
    ROUND(100 * SUM(en_riesgo) / COUNT(*), 2) AS pct_en_riesgo_segmento
FROM clientes_rfm
WHERE recencia <> 999
GROUP BY segmento_rfm;

-- Esperado: Alto 149 / 0 / 0.00 - Medio 266 / 0 / 0.00 - Bajo 487 / 271
-- / 55.65

-- ---------------------------------------------------------------------
-- B.2.7 Facturación en riesgo. Medida: % Revenue en Riesgo. Es
-- la métrica que sostiene el hallazgo central del apartado 7.3: riesgo
-- alto en clientes y bajo en facturación.
-- ---------------------------------------------------------------------
SELECT
    ROUND(SUM(CASE WHEN r.en_riesgo = 1 THEN t.importe ELSE 0 END), 2) AS revenue_en_riesgo,
    ROUND(SUM(t.importe), 2)                                              AS revenue_total,
    ROUND(100 * SUM(CASE WHEN r.en_riesgo = 1 THEN t.importe ELSE 0 END)
              / SUM(t.importe), 2)                                        AS pct_revenue_en_riesgo
FROM transacciones t
JOIN clientes_rfm r ON r.customer_id = t.customer_id;

-- Esperado: 190444.17 | 1636931.76 | 11.63

-- ---------------------------------------------------------------------
-- B.2.8 Desempeño por tienda y canal. Único desglose por plaza admitido:
-- métricas de facturación, que se atribuyen a nivel de transacción y
-- reparten sin solapamiento.
-- ---------------------------------------------------------------------
SELECT
    ti.nombre                           AS unidad,
    ROUND(SUM(t.importe), 2)            AS revenue,
    ROUND(SUM(t.importe) / COUNT(*), 2) AS ticket_medio,
    ROUND( ( SUM(CASE WHEN YEAR(t.fecha) = 2025 THEN t.importe ELSE 0 END)
           - SUM(CASE WHEN YEAR(t.fecha) = 2024 THEN t.importe ELSE 0 END) )
           / SUM(CASE WHEN YEAR(t.fecha) = 2024 THEN t.importe ELSE 0 END) * 100, 2) AS crecimiento_pct,
    ROUND(100 * SUM(CASE WHEN r.en_riesgo = 1 THEN t.importe ELSE 0 END)
              / SUM(t.importe), 2)      AS pct_revenue_en_riesgo
FROM transacciones t
JOIN tiendas      ti ON ti.store_id   = t.store_id
JOIN clientes_rfm r  ON r.customer_id = t.customer_id
GROUP BY ti.nombre
ORDER BY revenue DESC;

-- Esperado: Web 372561.79 / 203.47 / -3.79 / 12.06 - Sevilla 327595.02 /
-- 202.09 / -8.68 / 11.70 - Barcelona 313822.12 / 204.98 / -5.35 / 9.32 -
-- Madrid 313477.52 / 205.56 / -3.39 / 12.61 - Valencia 309475.31 /
-- 207.56 / +3.83 / 12.41

-- ---------------------------------------------------------------------
-- B.2.9 Defensa estadística del umbral de riesgo. Verifica que los 233
-- días corresponden al percentil 70 de la distribución de recencia sobre
-- la base compradora (902 clientes, recencia al 01/01/2026).
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                       AS compradores,
    MIN(recencia)                  AS recencia_min,
    MAX(recencia)                  AS recencia_max,
    ROUND(AVG(recencia), 1)        AS recencia_media,
    ROUND(STDDEV_POP(recencia), 1) AS recencia_desvio,
    ROUND(100 * SUM(CASE WHEN recencia <= 233 THEN 1 ELSE 0 END)
              / COUNT(*), 2)       AS pct_bajo_umbral
FROM clientes_rfm
WHERE recencia <> 999;

-- Esperado: 902 | 1 | 1096 | 211.3 | 242.3 | 69.96. Con interpolación
-- lineal el P70 es 233,7 días y se trunca a 233: el 69,96% queda a o por
-- debajo del umbral. Con 234 quedarían fuera del riesgo tres clientes con
-- recencia exacta de 234 días (detalle en el notebook 03).

-- ---------------------------------------------------------------------
-- B.2.10 No aditividad de los conteos de cliente por tienda. Evidencia
-- de la limitación declarada en el apartado 9.1: clientes_rfm tiene
-- granularidad cliente, no cliente-tienda.
-- ---------------------------------------------------------------------
SELECT
    SUM(clientes_por_tienda)                                        AS suma_conteos_por_tienda,
    (SELECT COUNT(DISTINCT customer_id) FROM transacciones)         AS compradores_unicos,
    ROUND(SUM(clientes_por_tienda)
        / (SELECT COUNT(DISTINCT customer_id) FROM transacciones), 2) AS unidades_por_cliente
FROM (
    SELECT store_id, COUNT(DISTINCT customer_id) AS clientes_por_tienda
    FROM transacciones
    GROUP BY store_id
) x;

-- Esperado: 3123 | 902 | 3.46. Un mismo cliente opera en 3,46 plazas en
-- promedio, de modo que cualquier conteo de clientes desglosado por
-- tienda lo registraría varias veces.

-- ---------------------------------------------------------------------
-- B.2.11 Clientes prioritarios. Medidas: Clientes Prioritarios, Revenue
-- Clientes Prioritarios, % Valor en Riesgo en Prioritarios. Requiere la
-- vista v_retencion_prioridad (views_customer_analytics.sql).
-- ---------------------------------------------------------------------
SELECT
    SUM(es_prioritario)                                                AS clientes_prioritarios,
    ROUND(SUM(CASE WHEN es_prioritario = 1 THEN monetario ELSE 0 END), 2) AS revenue_prioritarios,
    ROUND(100 * SUM(CASE WHEN es_prioritario = 1 THEN monetario ELSE 0 END)
              / SUM(monetario), 2)                                     AS pct_valor_en_riesgo
FROM v_retencion_prioridad;

-- Esperado: 81 | 119757.77 | 62.88
