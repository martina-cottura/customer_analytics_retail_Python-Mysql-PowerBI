-- =====================================================================
-- CUMBRES OUTDOOR & DEPORTE · CAPA DE VISTAS ANALÍTICAS
-- Base: customer_analytics (MySQL)
--
-- Criterio de la capa: las vistas agregan, cruzan y exponen; no
-- calculan lógica de negocio. La segmentación RFM y el flag de churn se
-- calculan una sola vez en Python y se persisten en clientes_rfm.
--
-- Power BI NO se conecta a estas vistas: el modelo semántico importa
-- directamente las tablas del esquema estrella. Las vistas sirven para
-- la explotación analítica en SQL y para contrastar las cifras del
-- dashboard (informe, apartados 5.3, 5.4 y anexo B).
--
-- Nota sobre clientes.fecha_alta: el campo es inconsistente con las
-- transacciones (739 de 903 compradores registran compras anteriores a
-- su alta; informe, apartado 4.2). No se expone en ninguna vista.
-- =====================================================================


-- ---------------------------------------------------------------------
-- BASE · v_hechos_transacciones
-- Grano: 1 fila por transacción (8.000).
-- Uso: exploración ad-hoc y validación cruzada.
-- ADVERTENCIA: no conectar a Power BI como fuente del modelo semántico.
-- Aplanar el esquema estrella en una tabla ancha destruye el modelo
-- dimensional y traslada a SQL un trabajo que Power BI resuelve mejor.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_hechos_transacciones;
CREATE VIEW v_hechos_transacciones AS
SELECT
    t.transaction_id,
    t.fecha,
    YEAR(t.fecha)                                       AS anio,
    CAST(DATE_FORMAT(t.fecha, '%Y-%m-01') AS DATE)      AS periodo_mes,
    t.customer_id,
    c.nombre        AS cliente_nombre,
    c.canal_adquisicion,
    t.store_id,
    s.nombre        AS tienda_nombre,
    s.ciudad        AS tienda_ciudad,
    t.product_id,
    p.nombre        AS producto_nombre,
    p.categoria     AS producto_categoria,
    p.precio_base,
    t.cantidad,
    t.importe,
    CASE WHEN t.importe < 0 THEN 1 ELSE 0 END           AS es_devolucion,
    r.segmento_rfm,
    r.churn_riesgo
FROM transacciones t
LEFT JOIN clientes     c ON t.customer_id = c.customer_id
LEFT JOIN tiendas      s ON t.store_id    = s.store_id
LEFT JOIN productos    p ON t.product_id  = p.product_id
LEFT JOIN clientes_rfm r ON t.customer_id = r.customer_id;

-- ---------------------------------------------------------------------
-- BASE · v_rfm_cliente   (apoyo de Q3)
-- Grano: 1 fila por cliente registrado (1.000).
-- Uso: replica en SQL el detalle por cliente que ofrece el
-- drill-through de la Página 2, para contrastarlo. El dashboard no se
-- conecta a esta vista.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_rfm_cliente;
CREATE VIEW v_rfm_cliente AS
SELECT
    c.customer_id,
    c.nombre,
    c.ciudad,
    c.canal_adquisicion,
    r.recencia,
    r.frecuencia,
    r.monetario,
    r.segmento_rfm,
    r.churn_riesgo,
    r.fecha_calculo,
    -- Separa al cliente sin historial de compra (recencia = 999,
    -- placeholder) del comprador real. Evita que el no convertido se
    -- cuele en cualquier cálculo de churn.
    CASE WHEN r.recencia = 999 THEN 0 ELSE 1 END AS es_comprador
FROM clientes c
LEFT JOIN clientes_rfm r
       ON c.customer_id = r.customer_id;

-- =====================================================================
-- Q1 · ¿Cómo se distribuye el valor de la cartera de clientes?
-- ---------------------------------------------------------------------
-- v_distribucion_cartera
-- Grano: 1 fila por segmento RFM (4).
--
-- La pregunta es de FORMA de la distribución, no de ranking. Por eso
-- la vista trae las dos caras juntas: cuántos clientes hay en cada
-- segmento y cuánto valor acumulan. El hallazgo vive en el contraste
-- entre pct_clientes y pct_valor, no en ninguna de las dos columnas
-- por separado.
--
-- pct_valor_acumulado ordena los segmentos por peso económico y
-- acumula: es la lectura tipo Pareto.
--
-- AVG(recencia) excluye el placeholder 999, que inflaba el promedio del
-- segmento Sin Transacciones y contaminaba la comparación.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_rfm_segmento;
DROP VIEW IF EXISTS v_distribucion_cartera;
CREATE VIEW v_distribucion_cartera AS
SELECT
    segmento_rfm,
    COUNT(*)                                                        AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)              AS pct_clientes,
    SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END)                AS compradores,
    ROUND(AVG(CASE WHEN recencia <> 999 THEN recencia END), 0)      AS recencia_promedio,
    ROUND(AVG(frecuencia), 1)                                       AS frecuencia_promedio,
    ROUND(AVG(monetario), 2)                                        AS ltv_promedio,
    ROUND(SUM(monetario), 2)                                        AS valor_total,
    ROUND(100.0 * SUM(monetario) / SUM(SUM(monetario)) OVER (), 1)  AS pct_valor,
    ROUND(100.0 * SUM(SUM(monetario)) OVER (ORDER BY SUM(monetario) DESC)
          / SUM(SUM(monetario)) OVER (), 1)                         AS pct_valor_acumulado,
    -- Índice de concentración: cuántas veces pesa más el segmento en
    -- valor que en cantidad de compradores (base 903, sin los 97 no
    -- convertidos). >1 = segmento sobre-indexado.
    ROUND((SUM(monetario) / SUM(SUM(monetario)) OVER ())
          / NULLIF(SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END)
                   / SUM(SUM(CASE WHEN recencia <> 999
                                  THEN 1 ELSE 0 END)) OVER (), 0), 2)
                                                                    AS indice_concentracion,
    SUM(churn_riesgo)                                               AS clientes_en_riesgo,
    ROUND(100.0 * SUM(churn_riesgo)
          / NULLIF(SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END), 0), 1)
                                                                    AS pct_en_riesgo,
    MAX(fecha_calculo)                                              AS fecha_snapshot
FROM clientes_rfm
GROUP BY segmento_rfm;

-- =====================================================================
-- Q2 · ¿Qué segmentos concentran la mayor contribución al negocio?
-- ---------------------------------------------------------------------
-- v_contribucion_segmento_anio
-- Grano: segmento RFM × año.
--
-- POR QUÉ NO ALCANZA CON Q1: v_distribucion_cartera mide el valor
-- acumulado histórico del snapshot RFM. Esta vista mide la
-- contribución REAL sobre la tabla de hechos, y la abre por año.
-- Una dice cuánto vale el segmento; la otra, si ese peso crece o cae.
--
-- ADVERTENCIA DE LECTURA: el segmento es un snapshot calculado a la
-- fecha de referencia y se aplica retroactivamente a transacciones de
-- 2023-2025. No es una serie de cohortes: dice cuánto facturó en 2023
-- quien HOY es Alto Valor, no quién era Alto Valor en 2023
-- (informe, apartado 9.1).
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_contribucion_segmento_anio;
CREATE VIEW v_contribucion_segmento_anio AS
SELECT
    YEAR(t.fecha)                                                    AS anio,
    r.segmento_rfm,
    COUNT(DISTINCT t.customer_id)                                    AS clientes_activos,
    COUNT(DISTINCT t.transaction_id)                                 AS transacciones,
    ROUND(SUM(t.importe), 2)                                         AS revenue,
    -- Participación del segmento DENTRO del año: permite comparar 2023
    -- con 2025 sin que el volumen total interfiera.
    ROUND(100.0 * SUM(t.importe)
          / SUM(SUM(t.importe)) OVER (PARTITION BY YEAR(t.fecha)), 1) AS pct_revenue_anio,
    ROUND(SUM(t.importe) / NULLIF(COUNT(DISTINCT t.transaction_id), 0), 2)
                                                                     AS ticket_medio,
    ROUND(COUNT(DISTINCT t.transaction_id)
          / NULLIF(COUNT(DISTINCT t.customer_id), 0), 2)             AS frecuencia,
    ROUND(SUM(t.importe) / NULLIF(COUNT(DISTINCT t.customer_id), 0), 2)
                                                                     AS revenue_por_cliente,
    SUM(CASE WHEN t.importe < 0 THEN 1 ELSE 0 END)                   AS devoluciones
FROM transacciones t
LEFT JOIN clientes_rfm r ON t.customer_id = r.customer_id
GROUP BY YEAR(t.fecha), r.segmento_rfm;

-- =====================================================================
-- Q3 · ¿Qué clientes presentan mayor riesgo de abandono?
-- ---------------------------------------------------------------------
-- v_retencion_prioridad
-- Grano: 1 fila por cliente en riesgo (269).
--
-- La pregunta, convertida en acción: no todos los clientes en riesgo
-- merecen la misma inversión de retención. La vista ordena por
-- facturación histórica y alimenta la recomendación del capítulo 8.
--
-- Usa el flag churn_riesgo persistido, NO un umbral de días escrito a
-- mano en SQL. Si el umbral cambia en Python, la vista sigue correcta.
--
-- pct_valor_en_riesgo y decil_valor permiten cortar la lista por
-- impacto: los deciles 1 a 3 (81 clientes) concentran el 62,7% de la
-- facturación asociada a clientes en riesgo. "Hay 269 clientes en
-- riesgo" no sostiene una decisión de presupuesto; ese corte sí.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_retencion_prioridad;
CREATE VIEW v_retencion_prioridad AS
SELECT
    c.customer_id,
    c.nombre,
    c.ciudad,
    c.canal_adquisicion,
    r.segmento_rfm,
    r.recencia,
    r.frecuencia,
    r.monetario,
    ROUND(r.monetario / NULLIF(r.frecuencia, 0), 2)                  AS ticket_historico,
    ROUND(100.0 * r.monetario / SUM(r.monetario) OVER (), 2)         AS pct_valor_en_riesgo,
    NTILE(10) OVER (ORDER BY r.monetario DESC)                       AS decil_valor,
    r.fecha_calculo
FROM clientes c
JOIN clientes_rfm r ON c.customer_id = r.customer_id
WHERE r.churn_riesgo = 1
  AND r.recencia <> 999;

-- =====================================================================
-- Q4 · ¿Cómo varía el comportamiento de compra entre puntos de venta
--      y categorías de producto?
-- ---------------------------------------------------------------------
-- v_categoria_tienda
-- Grano: categoría de producto × punto de venta (4 × 5).
--
-- Tres porcentajes porque responden preguntas distintas:
--   · pct_revenue_total  → peso de la celda sobre el revenue global.
--   · pct_revenue_tienda → mix interno de cada tienda. Es el que
--     detecta especialización de un punto de venta.
--   · indice_mix         → mix de la tienda contra el mix global de la
--     categoría. >1 = la categoría pesa más acá que en el promedio de
--     la cadena.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_categoria_producto;
DROP VIEW IF EXISTS v_categoria_canal;
DROP VIEW IF EXISTS v_categoria_tienda;
CREATE VIEW v_categoria_tienda AS
SELECT
    p.categoria,
    t.store_id,
    s.nombre                                                         AS tienda_nombre,
    COUNT(DISTINCT t.transaction_id)                                 AS transacciones,
    ROUND(SUM(t.importe), 2)                                         AS revenue,
    ROUND(100.0 * SUM(t.importe) / SUM(SUM(t.importe)) OVER (), 1)   AS pct_revenue_total,
    ROUND(100.0 * SUM(t.importe)
          / SUM(SUM(t.importe)) OVER (PARTITION BY t.store_id), 1)   AS pct_revenue_tienda,
    ROUND((SUM(t.importe) / SUM(SUM(t.importe)) OVER (PARTITION BY t.store_id))
          / NULLIF(SUM(SUM(t.importe)) OVER (PARTITION BY p.categoria)
                   / SUM(SUM(t.importe)) OVER (), 0), 2)             AS indice_mix,
    ROUND(SUM(t.importe) / NULLIF(COUNT(DISTINCT t.transaction_id), 0), 2)
                                                                     AS ticket_medio,
    SUM(t.cantidad)                                                  AS unidades
FROM transacciones t
LEFT JOIN productos p ON t.product_id = p.product_id
LEFT JOIN tiendas   s ON t.store_id   = s.store_id
GROUP BY p.categoria, t.store_id, s.nombre;

-- ---------------------------------------------------------------------
-- RETIRADA · v_desempeno_tienda_segmento (punto de venta × segmento RFM)
--
-- Esta vista se eliminó de la capa. Cruzaba el punto de venta con el
-- segmento RFM y exponía un COUNT(DISTINCT customer_id) por tienda, un
-- conteo que parece correcto y no lo es: un mismo comprador opera en
-- varias plazas, así que la columna suma vínculos cliente-tienda y no
-- personas (los 903 compradores generan 3.124 vínculos). Sumar las
-- cinco filas da 3.124, no 903.
--
-- Además, el cruce no aportaba señal: la participación de cada segmento
-- en la facturación es prácticamente idéntica en las cinco plazas (Alto
-- Valor entre 40,5% y 43,2% de la facturación de su tienda), diferencia
-- que cae dentro del margen de la propia base.
--
-- Criterio que queda fijado: el comportamiento del cliente se analiza
-- a nivel de cartera; el desglose por punto de venta se apoya sólo en
-- facturación, que sí se atribuye a nivel de transacción y reparte sin
-- solapamiento. Los DROP quedan para limpiar instalaciones previas.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_desempen_canal_segmento;
DROP VIEW IF EXISTS v_desempeno_canal_segmento;
DROP VIEW IF EXISTS v_desempeno_tienda_segmento;


-- ---------------------------------------------------------------------
-- v_temporal_tienda
-- Grano: mes × punto de venta.
-- Uso: reproduce en SQL la evolución temporal que la Página 1 calcula
-- sobre la tabla de hechos, para contrastarla. El dashboard no se
-- conecta a esta vista.
--
-- DATE_TRUNC(fecha, MONTH) es sintaxis de BigQuery y no existe en
-- MySQL. Se usa DATE_FORMAT + CAST a DATE para que la columna sea una
-- fecha real y no un texto: un texto no se ordena cronológicamente ni
-- se cruza por fecha con otras fuentes.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_temporal_tienda;
CREATE VIEW v_temporal_tienda AS
SELECT
    CAST(DATE_FORMAT(t.fecha, '%Y-%m-01') AS DATE)                   AS periodo,
    s.store_id,
    s.nombre                                                         AS tienda_nombre,
    s.ciudad                                                         AS tienda_ciudad,
    COUNT(DISTINCT t.transaction_id)                                 AS transacciones,
    ROUND(SUM(t.importe), 2)                                         AS revenue,
    ROUND(SUM(t.importe) / NULLIF(COUNT(DISTINCT t.transaction_id), 0), 2)
                                                                     AS ticket_medio
FROM transacciones t
LEFT JOIN tiendas s ON t.store_id = s.store_id
GROUP BY
    CAST(DATE_FORMAT(t.fecha, '%Y-%m-01') AS DATE),
    s.store_id, s.nombre, s.ciudad;

-- =====================================================================
-- Q5 · ¿Qué oportunidades de mejora pueden identificarse a partir del
--      análisis del comportamiento de los clientes?
-- ---------------------------------------------------------------------
-- v_adquisicion_conversion
-- Grano: canal de adquisición.
--
-- Aísla a los no convertidos por canal de captación y da base a la
-- recomendación de activación de primera compra. El canal de
-- adquisición es una dimensión del CLIENTE (cómo se lo captó), no del
-- punto de venta (dónde compró): son cosas distintas y no se mezclan.
--
-- pct_no_convertidos_total reparte los 97 no convertidos entre
-- canales. Resultado: el reparto es proporcional, de modo que la
-- recomendación de primera compra no admite priorización por origen.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_adquisicion_conversion;
CREATE VIEW v_adquisicion_conversion AS
SELECT
    c.canal_adquisicion,
    COUNT(*)                                                         AS clientes_captados,
    SUM(CASE WHEN r.recencia <> 999 THEN 1 ELSE 0 END)               AS compradores,
    SUM(CASE WHEN r.recencia  = 999 THEN 1 ELSE 0 END)               AS no_convertidos,
    ROUND(100.0 * SUM(CASE WHEN r.recencia <> 999 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 1)                                  AS tasa_conversion,
    ROUND(100.0 * SUM(CASE WHEN r.recencia = 999 THEN 1 ELSE 0 END)
          / NULLIF(SUM(SUM(CASE WHEN r.recencia = 999 THEN 1 ELSE 0 END)) OVER (), 0), 1)
                                                                     AS pct_no_convertidos_total,
    ROUND(AVG(CASE WHEN r.recencia <> 999 THEN r.monetario END), 2)  AS ltv_promedio_comprador,
    ROUND(SUM(r.monetario), 2)                                       AS valor_total,
    SUM(r.churn_riesgo)                                              AS clientes_en_riesgo
FROM clientes c
LEFT JOIN clientes_rfm r ON c.customer_id = r.customer_id
GROUP BY c.canal_adquisicion;

-- Vistas retiradas o de versiones previas (ver informe, apartado B.1).
DROP VIEW IF EXISTS
    v_rfm_segmento,
    v_desempen_canal_segmento,
    v_desempeno_tienda_segmento,
    v_categoria_producto,
    v_churn_segmento,
    v_evolucion_mensual,
    v_no_conversion_canal,
    v_ticket_canal,
    v_valor_categoria;
-- =====================================================================
-- BLOQUE 9 · EXPLOTACIÓN — una consulta por pregunta analítica
-- Correspondencia con las preguntas del apartado 2.4 del informe.
-- Cada consulta se apoya en su vista; no reescribe los JOIN.
-- =====================================================================

-- 9.Q1 · Forma de la distribución de la cartera.
SELECT segmento_rfm, clientes, pct_clientes, valor_total, pct_valor,
       pct_valor_acumulado, indice_concentracion
FROM v_distribucion_cartera
ORDER BY valor_total DESC;

-- 9.Q2 · Evolución de la contribución por segmento.
SELECT segmento_rfm,
       MAX(CASE WHEN anio = 2023 THEN pct_revenue_anio END) AS pct_2023,
       MAX(CASE WHEN anio = 2024 THEN pct_revenue_anio END) AS pct_2024,
       MAX(CASE WHEN anio = 2025 THEN pct_revenue_anio END) AS pct_2025
FROM v_contribucion_segmento_anio
GROUP BY segmento_rfm
ORDER BY pct_2025 DESC;

-- 9.Q3 · Concentración de la facturación en riesgo por decil. Es el
-- número que justifica priorizar.
SELECT decil_valor,
       COUNT(*)                           AS clientes,
       ROUND(SUM(monetario), 2)           AS valor_en_juego,
       ROUND(SUM(pct_valor_en_riesgo), 1) AS pct_del_total
FROM v_retencion_prioridad
GROUP BY decil_valor
ORDER BY decil_valor;

-- 9.Q4 · Especialización por tienda: dónde una categoría sobre-indexa.
SELECT tienda_nombre, categoria, revenue, pct_revenue_tienda, indice_mix
FROM v_categoria_tienda
WHERE indice_mix >= 1.15
ORDER BY indice_mix DESC;

-- 9.Q5 · Dónde se concentran los no convertidos.
SELECT canal_adquisicion, clientes_captados, compradores, no_convertidos,
       tasa_conversion, pct_no_convertidos_total, ltv_promedio_comprador
FROM v_adquisicion_conversion
ORDER BY no_convertidos DESC;

-- =====================================================================
-- BLOQUE 10 · VALIDACIÓN DE LA CAPA
-- Controles de salud de la capa relacional (informe, apartado B.1).
-- Se ejecutan después de cada regeneración de clientes_rfm desde Python.
-- No verifican cifras contra el modelo semántico: eso lo hace el
-- archivo customer_analytics_reconciliacion_mysql_powerbi.sql (B.2).
-- =====================================================================

-- 10.1 · Integridad referencial: los tres deben dar 0.
SELECT 'tx sin cliente'  AS control, COUNT(*) AS filas
FROM transacciones t LEFT JOIN clientes  c ON t.customer_id = c.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'tx sin tienda',   COUNT(*)
FROM transacciones t LEFT JOIN tiendas   s ON t.store_id   = s.store_id
WHERE s.store_id IS NULL
UNION ALL
SELECT 'tx sin producto', COUNT(*)
FROM transacciones t LEFT JOIN productos p ON t.product_id = p.product_id
WHERE p.product_id IS NULL;

-- 10.2 · Coherencia del snapshot RFM contra la tabla de hechos.
-- Si no coinciden, clientes_rfm quedó desfasada y hay que regenerarla
-- desde Python.
SELECT 'revenue transacciones' AS fuente, ROUND(SUM(importe), 2) AS valor FROM transacciones
UNION ALL
SELECT 'suma monetario RFM', ROUND(SUM(monetario), 2) FROM clientes_rfm;

SELECT 'compradores en transacciones' AS fuente, COUNT(DISTINCT customer_id) AS valor FROM transacciones
UNION ALL
SELECT 'compradores en RFM (recencia<>999)', COUNT(*) FROM clientes_rfm WHERE recencia <> 999;

-- 10.3 · Fecha de anclaje del snapshot: debe ser max(fecha) + 1 día.
SELECT
    MAX(t.fecha)                                  AS ultima_transaccion,
    (SELECT MAX(fecha_calculo) FROM clientes_rfm) AS fecha_calculo_rfm,
    DATEDIFF((SELECT MAX(fecha_calculo) FROM clientes_rfm), MAX(t.fecha)) AS dias_diferencia
FROM transacciones t;

-- 10.4 · Umbral de churn efectivamente persistido. Si no delimita los
-- 234 días (percentil 70 calculado en Python), hay que corregir el
-- COMMENT de la columna y el informe. Esperado: 234 | 236 | 0.
SELECT
    MAX(CASE WHEN churn_riesgo = 0 THEN recencia END) AS max_recencia_activo,
    MIN(CASE WHEN churn_riesgo = 1 THEN recencia END) AS min_recencia_en_riesgo,
    SUM(CASE WHEN churn_riesgo = 1 AND recencia = 999 THEN 1 ELSE 0 END)
                                                      AS inconsistencias_999
FROM clientes_rfm
WHERE recencia <> 999 OR churn_riesgo = 1;

-- 10.5 · Distribución de recencia por tramos mensuales: base empírica
-- del umbral, complementaria de la consulta B.2.9 del informe.
SELECT
    FLOOR(recencia / 30)      AS meses_desde_ultima_compra,
    COUNT(*)                  AS clientes,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM clientes_rfm
WHERE recencia <> 999
GROUP BY FLOOR(recencia / 30)
ORDER BY meses_desde_ultima_compra;

-- 10.6 · Cifras de cabecera del dashboard.
SELECT 'Clientes registrados'   AS metrica, COUNT(*) AS valor FROM clientes
UNION ALL SELECT 'Clientes compradores', COUNT(DISTINCT customer_id) FROM transacciones
UNION ALL SELECT 'Transacciones',        COUNT(*)                    FROM transacciones
UNION ALL SELECT 'Devoluciones',         COUNT(*)                    FROM transacciones WHERE importe < 0
UNION ALL SELECT 'Revenue neto (EUR)',   ROUND(SUM(importe), 2)      FROM transacciones
UNION ALL SELECT 'Ticket medio (EUR)',   ROUND(SUM(importe) / COUNT(DISTINCT transaction_id), 2) FROM transacciones
UNION ALL SELECT 'Frecuencia por comprador',
       ROUND(COUNT(*) / COUNT(DISTINCT customer_id), 2) FROM transacciones;

-- 10.7 · Churn: las dos lecturas posibles, explicitadas. La diferencia
-- cambia el titular del dashboard; el informe usa la de compradores.
SELECT
    'sobre compradores'                                              AS alcance,
    SUM(churn_riesgo)                                                AS en_riesgo,
    SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END)                 AS base,
    ROUND(100.0 * SUM(churn_riesgo)
          / NULLIF(SUM(CASE WHEN recencia <> 999 THEN 1 ELSE 0 END), 0), 2) AS pct
FROM clientes_rfm
UNION ALL
SELECT
    'sobre base registrada',
    SUM(churn_riesgo),
    COUNT(*),
    ROUND(100.0 * SUM(churn_riesgo) / COUNT(*), 2)
FROM clientes_rfm;

-- 10.8 · Inventario: deben ser 8 vistas. No debe figurar
-- v_desempeno_tienda_segmento ni ningún nombre de versiones previas.
SELECT TABLE_NAME
FROM INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA = 'customer_analytics'
ORDER BY TABLE_NAME;

-- 10.9 · Lectura Web frente a física. Evidencia que respalda haber
-- bajado el canal de dimensión analítica a simple atributo de la
-- dimensión de tiendas, sin uso en el dashboard (informe, apartado 5.4).
SELECT
    CASE WHEN store_id = 'T05' THEN 'Web (T05)' ELSE 'Física (T01-T04)' END AS lectura_canal,
    COUNT(DISTINCT transaction_id)                                   AS transacciones,
    COUNT(DISTINCT customer_id)                                      AS clientes,
    ROUND(SUM(importe), 2)                                           AS revenue,
    ROUND(100.0 * SUM(importe) / SUM(SUM(importe)) OVER (), 1)       AS pct_revenue,
    ROUND(SUM(importe) / NULLIF(COUNT(DISTINCT transaction_id), 0), 2) AS ticket_medio,
    ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT customer_id), 0), 2)      AS frecuencia
FROM transacciones
GROUP BY CASE WHEN store_id = 'T05' THEN 'Web (T05)' ELSE 'Física (T01-T04)' END;

-- 10.10 · Coherencia contra el dashboard.
-- Comparar contra los KPI de la Página 1. Una discrepancia es un
-- problema real de la capa SQL o del modelo semántico, no un detalle de
-- redacción: se resuelve antes de escribir ninguna cifra.
SELECT 'Revenue total'  AS kpi, ROUND(SUM(importe), 2) AS sql_valor FROM transacciones
UNION ALL SELECT 'Clientes compradores', COUNT(DISTINCT customer_id) FROM transacciones
UNION ALL SELECT 'Transacciones',        COUNT(*)                    FROM transacciones
UNION ALL SELECT 'Revenue 2024', ROUND(SUM(importe), 2) FROM transacciones WHERE YEAR(fecha) = 2024
UNION ALL SELECT 'Revenue 2025', ROUND(SUM(importe), 2) FROM transacciones WHERE YEAR(fecha) = 2025;
