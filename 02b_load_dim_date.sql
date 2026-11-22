/* TransLog Maroc (societe FICTIVE) - Alimentation de dwh.dim_date pour 2026.
   Rejouable : n'insere que les dates absentes. */
USE translog_dw;
GO

WITH d AS (
    SELECT CAST('2026-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt) FROM d WHERE dt < '2026-12-31'
)
INSERT INTO dwh.dim_date (date_key, date_complete, annee, mois, jour)
SELECT YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt),
       dt, YEAR(dt), MONTH(dt), DAY(dt)
FROM d
WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date x WHERE x.date_complete = d.dt)
OPTION (MAXRECURSION 400);
GO

SELECT COUNT(*) AS nb_dates FROM dwh.dim_date;   -- attendu : 365
GO
