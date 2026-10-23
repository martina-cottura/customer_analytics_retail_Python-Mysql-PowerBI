-- ================================================================
-- CUMBRES OUTDOOR & DEPORTE · CUSTOMER ANALYTICS
-- Esquema, carga y tablas finales (MySQL 9.4)
-- ================================================================
-- Orden de ejecución del proyecto:
--   1. este archivo                         esquema estrella y carga
--   2. views_customer_analytics.sql         capa de vistas y validación
--   3. customer_analytics_reconciliacion_mysql_powerbi.sql
--                                           reconciliación contra Power BI
--
-- Los CSV se generan en los notebooks de python/ y deben copiarse a la
-- carpeta habilitada por secure_file_priv:
--   C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/
-- clientes_rfm.csv sale de 03_construccion_rfm.ipynb: si se regenera
-- el notebook, hay que volver a copiarlo antes de ejecutar el PASO 4.
--
-- El script es re-ejecutable de principio a fin. Si un control no da
-- el valor esperado, detenerse y ejecutar SHOW WARNINGS;
-- ================================================================

CREATE DATABASE IF NOT EXISTS customer_analytics
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE customer_analytics;

-- ================================================================
-- PASO 1: STAGING Y CARGA DE CSV
-- Todas las columnas como texto: la conversión de tipos se hace en el
-- PASO 3, donde un valor inválido falla de forma visible.
-- ================================================================

DROP TABLE IF EXISTS stg_transacciones, stg_clientes, stg_productos, stg_tiendas;

CREATE TABLE stg_tiendas (
    store_id    VARCHAR(50),
    nombre      VARCHAR(100),
    ciudad      VARCHAR(100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stg_clientes (
    customer_id       VARCHAR(50),
    nombre            VARCHAR(100),
    email             VARCHAR(100),
    ciudad            VARCHAR(100),
    canal_adquisicion VARCHAR(50),
    fecha_alta        VARCHAR(20),
    anio_mes          VARCHAR(10)   -- viene en el CSV; no pasa a la tabla final
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stg_productos (
    product_id  VARCHAR(50),
    nombre      VARCHAR(100),
    categoria   VARCHAR(50),
    precio_base VARCHAR(20)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE stg_transacciones (
    transaction_id VARCHAR(50),
    customer_id    VARCHAR(50),
    product_id     VARCHAR(50),
    store_id       VARCHAR(50),
    cantidad       VARCHAR(10),
    importe        VARCHAR(20),
    fecha          VARCHAR(20)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/tiendas_clean.csv'
INTO TABLE stg_tiendas
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(store_id, nombre, ciudad);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/clientes_clean.csv'
INTO TABLE stg_clientes
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(customer_id, nombre, email, ciudad, canal_adquisicion, fecha_alta, anio_mes);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/productos_clean.csv'
INTO TABLE stg_productos
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(product_id, nombre, categoria, precio_base);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/transacciones_clean.csv'
INTO TABLE stg_transacciones
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(transaction_id, customer_id, product_id, store_id, cantidad, importe, fecha);

-- Control 1 · Esperado: 5 | 1000 | 48 | 8000. Si alguno da 0, falló el LOAD DATA.
SELECT
    (SELECT COUNT(*) FROM stg_tiendas)       AS stg_tiendas,
    (SELECT COUNT(*) FROM stg_clientes)      AS stg_clientes,
    (SELECT COUNT(*) FROM stg_productos)     AS stg_productos,
    (SELECT COUNT(*) FROM stg_transacciones) AS stg_transacciones;

-- ================================================================
-- PASO 2: TABLAS FINALES (esquema estrella)
-- Se eliminan en orden inverso a sus dependencias: primero las tablas
-- que referencian a otras, así no hace falta desactivar las FK.
-- ================================================================

DROP TABLE IF EXISTS clientes_rfm;
DROP TABLE IF EXISTS transacciones;
DROP TABLE IF EXISTS clientes;
DROP TABLE IF EXISTS productos;
DROP TABLE IF EXISTS tiendas;

CREATE TABLE tiendas (
    store_id    VARCHAR(3)   NOT NULL,
    nombre      VARCHAR(20)  NOT NULL,
    ciudad      VARCHAR(20)  NOT NULL,
    CONSTRAINT pk_tiendas PRIMARY KEY (store_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE clientes (
    customer_id       VARCHAR(5)   NOT NULL,
    nombre            VARCHAR(30)  NOT NULL,
    email             VARCHAR(40)      NULL,  -- ~4% nulos documentados
    ciudad            VARCHAR(20)      NULL,  -- ~5% nulos documentados
    canal_adquisicion VARCHAR(10)  NOT NULL,
    fecha_alta        DATE         NOT NULL,
    CONSTRAINT pk_clientes PRIMARY KEY (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE productos (
    product_id  VARCHAR(4)    NOT NULL,
    nombre      VARCHAR(25)   NOT NULL,
    categoria   VARCHAR(15)   NOT NULL,
    precio_base DECIMAL(10,2) NOT NULL,
    CONSTRAINT pk_productos PRIMARY KEY (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE transacciones (
    transaction_id VARCHAR(7)    NOT NULL,
    customer_id    VARCHAR(5)    NOT NULL,
    product_id     VARCHAR(4)    NOT NULL,
    store_id       VARCHAR(3)    NOT NULL,
    cantidad       TINYINT       NOT NULL,
    importe        DECIMAL(10,2) NOT NULL,  -- negativos = devoluciones documentadas
    fecha          DATE          NOT NULL,
    CONSTRAINT pk_transacciones  PRIMARY KEY (transaction_id),
    CONSTRAINT fk_trans_cliente  FOREIGN KEY (customer_id) REFERENCES clientes(customer_id),
    CONSTRAINT fk_trans_producto FOREIGN KEY (product_id)  REFERENCES productos(product_id),
    CONSTRAINT fk_trans_tienda   FOREIGN KEY (store_id)    REFERENCES tiendas(store_id),
    INDEX idx_trans_fecha    (fecha),
    INDEX idx_trans_store    (store_id),
    INDEX idx_trans_customer (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE INDEX idx_cli_canal      ON clientes (canal_adquisicion);
CREATE INDEX idx_prod_categoria ON productos (categoria);

-- ================================================================
-- PASO 3: STAGING → TABLAS FINALES
-- Conversión de tipos. Orden obligado por las FK:
-- tiendas → clientes → productos → transacciones.
-- ================================================================

INSERT INTO tiendas (store_id, nombre, ciudad)
SELECT TRIM(store_id), TRIM(nombre), TRIM(ciudad)
FROM stg_tiendas
WHERE NULLIF(TRIM(store_id), '') IS NOT NULL;

-- email y ciudad: cadena vacía → NULL
INSERT INTO clientes (customer_id, nombre, email, ciudad, canal_adquisicion, fecha_alta)
SELECT
    TRIM(customer_id),
    TRIM(nombre),
    NULLIF(TRIM(email), ''),
    NULLIF(TRIM(ciudad), ''),
    TRIM(canal_adquisicion),
    STR_TO_DATE(TRIM(fecha_alta), '%Y-%m-%d')
FROM stg_clientes
WHERE NULLIF(TRIM(customer_id), '') IS NOT NULL;

INSERT INTO productos (product_id, nombre, categoria, precio_base)
SELECT
    TRIM(product_id),
    TRIM(nombre),
    TRIM(categoria),
    CAST(REPLACE(TRIM(precio_base), ',', '.') AS DECIMAL(10,2))
FROM stg_productos
WHERE NULLIF(TRIM(product_id), '') IS NOT NULL;

INSERT INTO transacciones (transaction_id, customer_id, product_id, store_id, cantidad, importe, fecha)
SELECT
    TRIM(transaction_id),
    TRIM(customer_id),
    TRIM(product_id),
    TRIM(store_id),
    CAST(TRIM(cantidad) AS SIGNED),
    CAST(REPLACE(TRIM(importe), ',', '.') AS DECIMAL(10,2)),
    STR_TO_DATE(TRIM(fecha), '%Y-%m-%d')
FROM stg_transacciones
WHERE NULLIF(TRIM(transaction_id), '') IS NOT NULL;

-- Las FK ya impiden transacciones huérfanas: si el INSERT anterior no
-- falló, la integridad referencial está garantizada.

-- ================================================================
-- PASO 4: SNAPSHOT RFM
-- Origen: clientes_rfm.csv (03_construccion_rfm.ipynb). Segmentación y
-- churn_riesgo se calculan una única vez en Python; MySQL solo los
-- persiste. Umbral de churn: percentil 70 de la recencia de los 903
-- compradores al 2026-01-01 = 234 días.
-- ================================================================

CREATE TABLE clientes_rfm (
    customer_id    VARCHAR(5)    NOT NULL,
    recencia       INT           NOT NULL COMMENT 'Días desde la última compra al 2026-01-01; 999 = sin transacciones',
    frecuencia     INT           NOT NULL,
    monetario      DECIMAL(10,2) NOT NULL,
    segmento_rfm   VARCHAR(20)   NOT NULL,
    churn_riesgo   TINYINT       NOT NULL COMMENT '1 = en riesgo (recencia > P70 = 234 días al 2026-01-01); 0 = activo o sin transacciones',
    fecha_calculo  DATE          NOT NULL,
    CONSTRAINT pk_clientes_rfm PRIMARY KEY (customer_id),
    CONSTRAINT fk_rfm_cliente  FOREIGN KEY (customer_id) REFERENCES clientes(customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 9.4/Uploads/clientes_rfm.csv'
INTO TABLE clientes_rfm
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS
(customer_id, recencia, frecuencia, monetario, segmento_rfm, churn_riesgo, fecha_calculo);

-- ================================================================
-- PASO 5: CONTROLES FINALES
-- ================================================================

-- Control 2 · Filas. Esperado: 5 | 1000 | 48 | 8000 | 1000
SELECT
    (SELECT COUNT(*) FROM tiendas)       AS tiendas,
    (SELECT COUNT(*) FROM clientes)      AS clientes,
    (SELECT COUNT(*) FROM productos)     AS productos,
    (SELECT COUNT(*) FROM transacciones) AS transacciones,
    (SELECT COUNT(*) FROM clientes_rfm)  AS clientes_rfm;

-- Control 3 · Cifras de cabecera. Esperado: 903 | 1640308.39 | 205.04
SELECT
    COUNT(DISTINCT customer_id) AS compradores,
    ROUND(SUM(importe), 2)      AS revenue_total,
    ROUND(AVG(importe), 2)      AS ticket_medio
FROM transacciones;

-- Control 4 · Segmentos. Esperado: Alto 149 / Medio 267 / Bajo 487 / Sin Transacciones 97
SELECT segmento_rfm, COUNT(*) AS clientes
FROM clientes_rfm
GROUP BY segmento_rfm
ORDER BY FIELD(segmento_rfm, 'Alto Valor', 'Medio Valor', 'Bajo Valor', 'Sin Transacciones');

-- Control 5 · Snapshot y churn. Esperado: 2026-01-01 | 1 | 269 | 29.79 | 234 | 236 | 0
--   · dias_desde_ultima_compra = 1: la fecha de referencia es la última transacción + 1 día.
--   · 269 en riesgo sobre 903 compradores. Si da 267, el CSV de Uploads es el anterior.
--   · 234 / 236: recencia máxima de un activo y mínima de uno en riesgo (el umbral persistido).
--   · 0: ningún cliente sin transacciones (recencia 999) figura en riesgo.
SELECT
    MAX(r.fecha_calculo)                                              AS fecha_calculo,
    DATEDIFF(MAX(r.fecha_calculo), (SELECT MAX(fecha) FROM transacciones))
                                                                      AS dias_desde_ultima_compra,
    SUM(r.churn_riesgo)                                               AS en_riesgo,
    ROUND(100 * SUM(r.churn_riesgo)
          / SUM(CASE WHEN r.recencia <> 999 THEN 1 ELSE 0 END), 2)    AS pct_en_riesgo,
    MAX(CASE WHEN r.churn_riesgo = 0 AND r.recencia <> 999 THEN r.recencia END)
                                                                      AS max_recencia_activo,
    MIN(CASE WHEN r.churn_riesgo = 1 THEN r.recencia END)             AS min_recencia_en_riesgo,
    SUM(CASE WHEN r.churn_riesgo = 1 AND r.recencia = 999 THEN 1 ELSE 0 END)
                                                                      AS inconsistencias_999
FROM clientes_rfm r;

-- ================================================================
-- PASO 6: LIMPIEZA DE STAGING
-- ================================================================

DROP TABLE IF EXISTS stg_transacciones, stg_clientes, stg_productos, stg_tiendas;

-- Siguiente: views_customer_analytics.sql
