/* TransLog Maroc (societe FICTIVE) - Liaison de fact_expedition a la dimension client SCD2.
   Chaque expedition pointe vers la version du client valide a la date de l'expedition :
   une analyse par ville utilise donc la ville du client au moment de l'expedition.
   client_key (type 1, valeurs actuelles) est conserve ; client_scd2_key donne l'historique.
   Prerequis : 05_scd2_client.sql. A executer apres le chargement initial (P2). */
USE translog_dw;
GO

-- 1) Nouvelle cle etrangere dans la table de faits
IF COL_LENGTH('dwh.fact_expedition', 'client_scd2_key') IS NULL
    ALTER TABLE dwh.fact_expedition ADD client_scd2_key INT NULL
        CONSTRAINT fk_fact_expedition_client_scd2 REFERENCES dwh.dim_client_scd2(client_key);
GO

-- 2) La premiere version de chaque client est valide depuis l'origine
UPDATE c
   SET c.date_debut = '1900-01-01'
  FROM dwh.dim_client_scd2 c
 WHERE c.date_debut > '1900-01-01'
   AND NOT EXISTS (SELECT 1 FROM dwh.dim_client_scd2 p
                    WHERE p.id_client = c.id_client AND p.date_debut < c.date_debut);
GO

-- 3) Procedure de liaison, rejouable : ne modifie que les faits sans version ou mal lies
CREATE OR ALTER PROCEDURE etl.usp_lier_faits_scd2
    @afficher BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @lies INT;

    UPDATE f
       SET f.client_scd2_key = v.client_key
      FROM dwh.fact_expedition f
      JOIN dwh.dim_client c       ON c.client_key = f.client_key
      JOIN dwh.dim_date d         ON d.date_key   = f.date_key
      JOIN dwh.dim_client_scd2 v  ON v.id_client  = c.id_client
                                 AND d.date_complete BETWEEN v.date_debut AND v.date_fin
     WHERE f.client_scd2_key IS NULL OR f.client_scd2_key <> v.client_key;

    SET @lies = @@ROWCOUNT;

    IF @afficher = 1
        SELECT @lies AS faits_lies,
               (SELECT COUNT(*) FROM dwh.fact_expedition WHERE client_scd2_key IS NULL) AS faits_sans_version;
END;
GO

-- 4) Versions SCD2 a jour (nouveaux clients compris), puis liaison
EXEC etl.usp_load_dim_client_scd2;
EXEC etl.usp_lier_faits_scd2;
GO

-- 5) Controle : le client 7 a demenage (SCD2). Ville au moment de l'expedition
--    (version SCD2) contre ville actuelle (dimension type 1).
SELECT TOP (10) f.expedition_id, d.date_complete,
       v.ville AS ville_a_la_date, c.ville AS ville_actuelle, v.date_debut, v.date_fin
FROM dwh.fact_expedition f
JOIN dwh.dim_date d ON d.date_key = f.date_key
JOIN dwh.dim_client c ON c.client_key = f.client_key
JOIN dwh.dim_client_scd2 v ON v.client_key = f.client_scd2_key
WHERE v.id_client = 7
ORDER BY d.date_complete DESC;
GO
