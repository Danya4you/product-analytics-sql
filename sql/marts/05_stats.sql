-- =============================================================================
-- marts/05_stats.sql — минимальная статистика прямо в базе
--
-- Нужна ровно для одного: посчитать значимость A/B-теста, не выгружая данные
-- в Python. В PostgreSQL 17 нет ни erf(), ни функции нормального распределения
-- (erf появился только в 18-й версии), поэтому нормальная функция
-- распределения считается приближением Зелена — Северо (Abramowitz & Stegun,
-- формула 26.2.17). Абсолютная погрешность не превышает 7,5e-8 — для
-- p-значений на порядки больше, чем нужно.
--
-- Если база 18-й версии, всю эту машинерию заменяет одна строка:
--     cdf = 0.5 * erfc(-x / sqrt(2))
-- =============================================================================

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION marts.norm_cdf(x double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN x >= 0 THEN 1 - p ELSE p END
    FROM (
        SELECT d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937
                      + t * (-1.821255978 + t * 1.330274429)))) AS p
        FROM (
            SELECT 1.0 / (1.0 + 0.2316419 * abs(x))                  AS t,
                   0.3989422804014327 * exp(-x * x / 2.0)            AS d
        ) s
    ) q
$$;

COMMENT ON FUNCTION marts.norm_cdf(double precision) IS
    'Функция стандартного нормального распределения. Приближение Зелена — Северо, погрешность < 7.5e-8.';

-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION marts.p_value_two_sided(z double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT 2 * (1 - marts.norm_cdf(abs(z)))
$$;

COMMENT ON FUNCTION marts.p_value_two_sided(double precision) IS
    'Двустороннее p-значение по z-статистике.';

-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION marts.z_two_proportions(
    x1 bigint, n1 bigint,      -- успехи и размер контрольной группы
    x2 bigint, n2 bigint       -- успехи и размер тестовой группы
) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    -- Стандартная ошибка считается по объединённой доле: это нулевая гипотеза
    -- «доли равны», и оценивать разброс надо при её условии.
    SELECT CASE WHEN se = 0 THEN 0 ELSE (p2 - p1) / se END
    FROM (
        SELECT p1, p2,
               sqrt(p * (1 - p) * (1.0 / n1 + 1.0 / n2)) AS se
        FROM (
            SELECT x1::double precision / n1              AS p1,
                   x2::double precision / n2              AS p2,
                   (x1 + x2)::double precision / (n1 + n2) AS p
        ) r
    ) s
$$;

COMMENT ON FUNCTION marts.z_two_proportions(bigint, bigint, bigint, bigint) IS
    'z-статистика для сравнения двух долей. Положительная — вторая группа выше первой.';

-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION marts.ci95_diff_proportions(
    x1 bigint, n1 bigint,
    x2 bigint, n2 bigint,
    bound text DEFAULT 'low'   -- low | high
) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    -- Здесь, в отличие от z-статистики, стандартная ошибка НЕ объединённая:
    -- интервал строится вокруг наблюдаемой разницы, а не при нулевой гипотезе.
    SELECT CASE WHEN bound = 'low' THEN diff - 1.959964 * se
                ELSE diff + 1.959964 * se END
    FROM (
        SELECT x2::double precision / n2 - x1::double precision / n1 AS diff,
               sqrt(
                   (x1::double precision / n1) * (1 - x1::double precision / n1) / n1
                 + (x2::double precision / n2) * (1 - x2::double precision / n2) / n2
               ) AS se
    ) s
$$;

COMMENT ON FUNCTION marts.ci95_diff_proportions(bigint, bigint, bigint, bigint, text) IS
    '95-процентный доверительный интервал разницы двух долей (доля2 минус доля1).';
