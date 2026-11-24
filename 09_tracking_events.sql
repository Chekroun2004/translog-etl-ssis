/* TransLog Maroc (societe FICTIVE) - P4 : evenements de suivi issus de l'API REST.
   Flux : API -> ingest_tracking.py -> CSV -> staging -> dwh.fact_suivi_evenement.
   Grain de la table de faits : UN evenement de suivi d'UNE expedition.
   Watermark : dernier id_evenement deja traite (l'API pagine par curseur sur cet id).
   Limite connue : un evenement rejete (ex. expedition inconnue) est journalise dans
   etl.rejet mais n'est plus redemande a l'API : la perte est tracee, pas silencieuse. */
USE translog_dw;
GO

IF OBJECT_ID('stg.tracking_events') IS NULL
CREATE TABLE stg.tracking_events (
    id_evenement  NVARCHAR(20),
    id_expedition NVARCHAR(20),
    statut        NVARCHAR(50),
    horodatage    NVARCHAR(30)
);
GO

IF OBJECT_ID('dwh.fact_suivi_evenement') IS NULL
CREATE TABLE dwh.fact_suivi_evenement (
    evenement_id  INT          NOT NULL PRIMARY KEY,   -- degenerate dimension (id de l'API)
    expedition_id INT          NOT NULL REFERENCES dwh.fact_expedition(expedition_id),
    statut_key    INT          NOT NULL REFERENCES dwh.dim_statut(statut_key),
    date_key      INT          NOT NULL REFERENCES dwh.dim_date(date_key),
    horodatage    DATETIME2(0) NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM etl.watermark WHERE nom_flux = 'tracking_events')
    INSERT INTO etl.watermark (nom_flux, derniere_valeur) VALUES ('tracking_events', 0);
GO

CREATE OR ALTER PROCEDURE etl.usp_load_tracking_events
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @wm BIGINT, @nouveau_wm BIGINT, @nb INT, @nb_rej INT;

    SELECT @wm = derniere_valeur FROM etl.watermark WHERE nom_flux = 'tracking_events';
    IF @wm IS NULL
        THROW 50002, 'Watermark absent pour tracking_events', 1;

    /* Typage et detection des doublons dans le lot. */
    SELECT TRY_CAST(id_evenement AS INT)                 AS evenement_id,
           id_evenement                                  AS id_brut,
           TRY_CAST(id_expedition AS INT)                AS expedition_id,
           LTRIM(RTRIM(statut))                          AS statut,
           TRY_CAST(horodatage AS DATETIME2(0))          AS horodatage,
           ROW_NUMBER() OVER (PARTITION BY id_evenement
                              ORDER BY (SELECT NULL))    AS rn
    INTO #src
    FROM stg.tracking_events;

    /* Verdict ligne par ligne : motif NULL = ligne valide. */
    SELECT s.*, f.expedition_id AS exp_ok, st.statut_key, d.date_key,
           CASE
             WHEN s.evenement_id IS NULL                  THEN 'id evenement invalide'
             WHEN s.rn > 1                                THEN 'doublon'
             WHEN s.horodatage IS NULL                    THEN 'horodatage invalide'
             WHEN f.expedition_id IS NULL                 THEN 'expedition inconnue'
             WHEN st.statut_key IS NULL                   THEN 'statut inconnu'
             WHEN d.date_key IS NULL                      THEN 'date inconnue'
           END AS motif
    INTO #verdict
    FROM #src s
    LEFT JOIN dwh.fact_expedition f ON f.expedition_id = s.expedition_id
    LEFT JOIN dwh.dim_statut st     ON st.statut = s.statut
    LEFT JOIN dwh.dim_date d        ON d.date_complete = CAST(s.horodatage AS DATE);

    /* Rejeu : un evenement deja charge n'est ni recharge ni rejete (idempotence). */
    DELETE v FROM #verdict v
    WHERE v.motif IS NULL
      AND EXISTS (SELECT 1 FROM dwh.fact_suivi_evenement t WHERE t.evenement_id = v.evenement_id);

    SELECT @nb     = ISNULL(SUM(CASE WHEN motif IS NULL THEN 1 ELSE 0 END), 0),
           @nb_rej = ISNULL(SUM(CASE WHEN motif IS NOT NULL THEN 1 ELSE 0 END), 0)
    FROM #verdict;
    SELECT @nouveau_wm = MAX(evenement_id) FROM #src WHERE evenement_id IS NOT NULL;

    BEGIN TRAN;

    INSERT INTO dwh.fact_suivi_evenement (evenement_id, expedition_id, statut_key, date_key, horodatage)
    SELECT evenement_id, expedition_id, statut_key, date_key, horodatage
    FROM #verdict WHERE motif IS NULL;

    INSERT INTO etl.rejet (table_source, cle_source, motif)
    SELECT 'tracking_events', id_brut, motif FROM #verdict WHERE motif IS NOT NULL;

    /* Le repere avance sur tout ce qui a ete vu (charge ou rejete), dans la meme transaction. */
    IF @nouveau_wm > @wm
        UPDATE etl.watermark
           SET derniere_valeur = @nouveau_wm, date_maj = SYSUTCDATETIME()
         WHERE nom_flux = 'tracking_events';

    COMMIT;

    SELECT @nb AS lignes_chargees,
           @nb_rej AS lignes_rejetees,
           CAST(@wm AS INT) AS ancien_watermark,
           CAST(CASE WHEN @nouveau_wm > @wm THEN @nouveau_wm ELSE @wm END AS INT) AS nouveau_watermark;
END;
GO
