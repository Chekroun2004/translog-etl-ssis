/* TransLog Maroc (societe FICTIVE) - Journal des lignes rejetees. */
USE translog_dw;
GO

IF OBJECT_ID('etl.rejet') IS NULL
CREATE TABLE etl.rejet (
    rejet_id     INT IDENTITY(1,1) PRIMARY KEY,
    table_source NVARCHAR(100) NOT NULL,
    cle_source   NVARCHAR(50)  NULL,
    motif        NVARCHAR(200) NOT NULL,
    date_rejet   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Enregistre chaque expedition du staging qui n'a pas pu entrer dans la table de faits,
   avec son motif. Rejouable : le journal de cette source est vide avant d'etre reecrit. */
CREATE OR ALTER PROCEDURE etl.usp_log_rejets_expeditions AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM etl.rejet WHERE table_source = 'expeditions';

    WITH x AS (
        SELECT e.*,
               ROW_NUMBER() OVER (PARTITION BY id_expedition
                                  ORDER BY (SELECT NULL)) AS rn
        FROM stg.expeditions e
    )
    INSERT INTO etl.rejet (table_source, cle_source, motif)
    SELECT 'expeditions', id_expedition, motif
    FROM (
        SELECT x.id_expedition,
               CASE
                 WHEN rn > 1 THEN 'doublon'
                 WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_client c
                      WHERE c.id_client = TRY_CAST(x.id_client AS INT)) THEN 'client inconnu'
                 WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_entrepot en
                      WHERE en.id_entrepot = TRY_CAST(x.id_entrepot AS INT)) THEN 'entrepot inconnu'
                 WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_transporteur t
                      WHERE t.id_transporteur = TRY_CAST(x.id_transporteur AS INT)) THEN 'transporteur inconnu'
                 WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_statut s
                      WHERE s.statut = LTRIM(RTRIM(x.statut))) THEN 'statut inconnu'
                 WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_date d
                      WHERE d.date_complete = TRY_CAST(x.date_expedition AS DATE)) THEN 'date inconnue'
               END AS motif
        FROM x
    ) r
    WHERE motif IS NOT NULL;
END;
GO
