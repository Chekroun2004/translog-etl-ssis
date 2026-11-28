/* TransLog Maroc (societe FICTIVE) - Chargement incremental de fact_expedition.
   Principe : un watermark garde le plus grand id_expedition deja charge.
   Chaque execution ne traite que les expeditions au-dessus de ce repere.
   Choix : la source CSV n'a pas de date de modification, le watermark porte donc
   sur id_expedition (croissant). */
USE translog_dw;
GO

IF OBJECT_ID('etl.watermark') IS NULL
CREATE TABLE etl.watermark (
    nom_flux        VARCHAR(100) NOT NULL PRIMARY KEY,
    derniere_valeur BIGINT       NOT NULL,
    date_maj        DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Initialisation : on part de ce qui est deja dans la table de faits
   (chargee en full load par le package SSIS). */
IF NOT EXISTS (SELECT 1 FROM etl.watermark WHERE nom_flux = 'fact_expedition')
    INSERT INTO etl.watermark (nom_flux, derniere_valeur)
    SELECT 'fact_expedition', ISNULL(MAX(expedition_id), 0)
    FROM dwh.fact_expedition;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_fact_expedition_incr
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @wm BIGINT, @nouveau_wm BIGINT, @nb INT;

    SELECT @wm = derniere_valeur
    FROM etl.watermark
    WHERE nom_flux = 'fact_expedition';

    IF @wm IS NULL
        THROW 50001, 'Watermark absent pour fact_expedition', 1;

    /* NULLIF(x, '') : TRY_CAST('' AS INT) renvoie 0, pas NULL.
       Un delai vide doit rester inconnu, pas devenir 0 jour. */
    WITH src AS (
        SELECT TRY_CAST(id_expedition AS INT)                   AS expedition_id,
               TRY_CAST(id_client AS INT)                       AS id_client,
               TRY_CAST(id_entrepot AS INT)                     AS id_entrepot,
               TRY_CAST(id_transporteur AS INT)                 AS id_transporteur,
               TRY_CAST(date_expedition AS DATE)                AS date_expedition,
               LTRIM(RTRIM(statut))                             AS statut,
               TRY_CAST(NULLIF(poids_kg, '') AS DECIMAL(10,2))  AS poids_kg,
               TRY_CAST(NULLIF(volume_m3, '') AS DECIMAL(10,2)) AS volume_m3,
               TRY_CAST(NULLIF(delai_prevu_jours, '') AS INT)   AS delai_prevu_jours,
               TRY_CAST(NULLIF(delai_reel_jours, '') AS INT)    AS delai_reel_jours,
               ROW_NUMBER() OVER (PARTITION BY id_expedition
                                  ORDER BY (SELECT NULL))       AS rn
        FROM stg.expeditions
    )
    SELECT s.expedition_id, c.client_key, e.entrepot_key, t.transporteur_key,
           d.date_key, st.statut_key, s.poids_kg, s.volume_m3,
           s.delai_prevu_jours, s.delai_reel_jours
    INTO #nouveaux
    FROM src s
    JOIN dwh.dim_client       c  ON c.id_client        = s.id_client
    JOIN dwh.dim_entrepot     e  ON e.id_entrepot      = s.id_entrepot
    JOIN dwh.dim_transporteur t  ON t.id_transporteur  = s.id_transporteur
    JOIN dwh.dim_date         d  ON d.date_complete    = s.date_expedition
    JOIN dwh.dim_statut       st ON st.statut          = s.statut
    WHERE s.rn = 1
      AND s.expedition_id > @wm
      AND NOT EXISTS (SELECT 1 FROM dwh.fact_expedition f
                      WHERE f.expedition_id = s.expedition_id);

    SELECT @nb = COUNT(*), @nouveau_wm = MAX(expedition_id) FROM #nouveaux;

    BEGIN TRAN;

    INSERT INTO dwh.fact_expedition
        (expedition_id, client_key, entrepot_key, transporteur_key, date_key,
         statut_key, poids_kg, volume_m3, delai_prevu_jours, delai_reel_jours)
    SELECT expedition_id, client_key, entrepot_key, transporteur_key, date_key,
           statut_key, poids_kg, volume_m3, delai_prevu_jours, delai_reel_jours
    FROM #nouveaux;

    /* Le repere n'avance que si des lignes ont ete chargees,
       et dans la meme transaction que l'insertion. */
    IF @nb > 0
        UPDATE etl.watermark
           SET derniere_valeur = @nouveau_wm,
               date_maj = SYSUTCDATETIME()
         WHERE nom_flux = 'fact_expedition';

    COMMIT;

    /* Rattache les nouveaux faits a la version SCD2 du client valide a leur date. */
    EXEC etl.usp_lier_faits_scd2 @afficher = 0;

    /* Sortie en INT : plus simple a recuperer dans des variables SSIS Int32. */
    SELECT @nb AS lignes_chargees,
           CAST(@wm AS INT) AS ancien_watermark,
           CAST(ISNULL(@nouveau_wm, @wm) AS INT) AS nouveau_watermark;
END;
GO
