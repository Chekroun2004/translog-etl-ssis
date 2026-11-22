/* TransLog Maroc (societe FICTIVE) - P3 : dimension client en SCD type 2.
   On historise ville et adresse. Une ligne par version, avec sa periode de validite.
   Ligne courante : date_fin = 9999-12-31 et est_courant = 1. */
USE translog_dw;
GO

IF OBJECT_ID('dwh.dim_client_scd2') IS NULL
CREATE TABLE dwh.dim_client_scd2 (
    client_key   INT IDENTITY(1,1) PRIMARY KEY,
    id_client    INT           NOT NULL,
    nom          NVARCHAR(100) NULL,
    ville        NVARCHAR(100) NULL,
    adresse      NVARCHAR(200) NULL,
    date_debut   DATE          NOT NULL,
    date_fin     DATE          NOT NULL DEFAULT '9999-12-31',
    est_courant  BIT           NOT NULL DEFAULT 1
);
GO

/* Chargement en deux temps, dans une transaction :
   1) fermer les versions courantes dont ville ou adresse a change
   2) creer une version courante pour tout client qui n'en a pas
   Rejouable : sans changement dans le staging, rien n'est ecrit. */
CREATE OR ALTER PROCEDURE etl.usp_load_dim_client_scd2
    @date_effet DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @date_effet = ISNULL(@date_effet, CAST(SYSDATETIME() AS DATE));

    SELECT id_client, nom, ville, adresse
    INTO #src
    FROM (
        SELECT TRY_CAST(id_client AS INT) AS id_client, nom, ville, adresse,
               ROW_NUMBER() OVER (PARTITION BY TRY_CAST(id_client AS INT)
                                  ORDER BY (SELECT NULL)) AS rn
        FROM stg.clients
        WHERE TRY_CAST(id_client AS INT) IS NOT NULL
    ) x
    WHERE rn = 1;

    BEGIN TRAN;

    UPDATE t
       SET t.date_fin = DATEADD(DAY, -1, @date_effet),
           t.est_courant = 0
      FROM dwh.dim_client_scd2 t
      JOIN #src s ON s.id_client = t.id_client
     WHERE t.est_courant = 1
       AND (ISNULL(t.ville,'')   <> ISNULL(s.ville,'')
         OR ISNULL(t.adresse,'') <> ISNULL(s.adresse,''));

    INSERT INTO dwh.dim_client_scd2 (id_client, nom, ville, adresse, date_debut)
    SELECT s.id_client, s.nom, s.ville, s.adresse, @date_effet
      FROM #src s
     WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_client_scd2 t
                        WHERE t.id_client = s.id_client
                          AND t.est_courant = 1);

    COMMIT;
END;
GO

/* Exemple : ou habitait le client 7 a une date donnee ? */
-- SELECT ville, adresse
-- FROM dwh.dim_client_scd2
-- WHERE id_client = 7 AND '2026-03-10' BETWEEN date_debut AND date_fin;
