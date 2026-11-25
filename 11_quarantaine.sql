/* TransLog Maroc (societe FICTIVE) - P5 (suite) : quarantaine et retraitement des rejets.
   Probleme : un fait peut arriver AVANT sa reference (client, entrepot, expedition...).
   Le rejeter definitivement perd la donnee ; le charger avec une reference inventee
   la fausse. Choix : quarantaine. La ligne brute est gardee (JSON) avec un statut
   A_RETRAITER, puis retentee a chaque execution. Elle passe a RETRAITE une fois chargee,
   ou a ABANDONNE apres @max_essais tentatives (a surveiller dans P6).
   Seuls les motifs "inconnu" (reference absente pour l'instant) sont retentables :
   une valeur absente ou mal formee ne se corrigera pas toute seule.
   Ordre d'execution : 11_quarantaine.sql, puis 09_tracking_events.sql (procedure mise a jour). */
USE translog_dw;
GO

IF OBJECT_ID('etl.quarantaine') IS NULL
CREATE TABLE etl.quarantaine (
    quarantaine_id     INT IDENTITY(1,1) PRIMARY KEY,
    table_source       NVARCHAR(100) NOT NULL,
    cle_source         NVARCHAR(50)  NOT NULL,
    donnees_brutes     NVARCHAR(MAX) NOT NULL CHECK (ISJSON(donnees_brutes) = 1),
    motif              NVARCHAR(200) NOT NULL,
    statut             NVARCHAR(15)  NOT NULL DEFAULT 'A_RETRAITER'
        CHECK (statut IN ('A_RETRAITER', 'RETRAITE', 'ABANDONNE')),
    nb_essais          INT           NOT NULL DEFAULT 0,
    date_entree        DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    date_dernier_essai DATETIME2(0)  NULL,
    CONSTRAINT uq_quarantaine UNIQUE (table_source, cle_source)   -- rejouable
);
GO

/* Motif de rejet d'une expedition, en un seul endroit (inline table-valued function).
   Absent (vide) est teste avant inconnu : TRY_CAST('' AS INT) renvoie 0, pas NULL. */
CREATE OR ALTER FUNCTION etl.fn_motif_expedition (
    @id_client       NVARCHAR(20),
    @id_entrepot     NVARCHAR(20),
    @id_transporteur NVARCHAR(20),
    @date_expedition NVARCHAR(20),
    @statut          NVARCHAR(50))
RETURNS TABLE
AS RETURN
SELECT CASE
    WHEN NULLIF(LTRIM(RTRIM(@id_client)), '') IS NULL THEN N'client absent'
    WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_client c
                     WHERE c.id_client = TRY_CAST(@id_client AS INT)) THEN N'client inconnu'
    WHEN NULLIF(LTRIM(RTRIM(@id_entrepot)), '') IS NULL THEN N'entrepot absent'
    WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_entrepot e
                     WHERE e.id_entrepot = TRY_CAST(@id_entrepot AS INT)) THEN N'entrepot inconnu'
    WHEN NULLIF(LTRIM(RTRIM(@id_transporteur)), '') IS NULL THEN N'transporteur absent'
    WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_transporteur t
                     WHERE t.id_transporteur = TRY_CAST(@id_transporteur AS INT)) THEN N'transporteur inconnu'
    WHEN NULLIF(LTRIM(RTRIM(@statut)), '') IS NULL THEN N'statut absent'
    WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_statut s
                     WHERE s.statut = LTRIM(RTRIM(@statut))) THEN N'statut inconnu'
    WHEN TRY_CAST(@date_expedition AS DATE) IS NULL THEN N'date invalide'
    WHEN NOT EXISTS (SELECT 1 FROM dwh.dim_date d
                     WHERE d.date_complete = TRY_CAST(@date_expedition AS DATE)) THEN N'date inconnue'
END AS motif;
GO

/* Met en quarantaine les expeditions du staging absentes de la table de faits
   et dont le motif est retentable. Rejouable (UNIQUE + NOT EXISTS). */
CREATE OR ALTER PROCEDURE etl.usp_quarantaine_expeditions
AS
BEGIN
    SET NOCOUNT ON;

    WITH x AS (
        SELECT e.*,
               ROW_NUMBER() OVER (PARTITION BY id_expedition ORDER BY (SELECT NULL)) AS rn
        FROM stg.expeditions e
    )
    INSERT INTO etl.quarantaine (table_source, cle_source, donnees_brutes, motif)
    SELECT 'expeditions', x.id_expedition,
           (SELECT x.id_expedition, x.id_client, x.id_entrepot, x.id_transporteur,
                   x.date_expedition, x.poids_kg, x.volume_m3, x.statut,
                   x.delai_prevu_jours, x.delai_reel_jours
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           m.motif
    FROM x
    CROSS APPLY etl.fn_motif_expedition(x.id_client, x.id_entrepot, x.id_transporteur,
                                        x.date_expedition, x.statut) m
    WHERE x.rn = 1
      AND m.motif LIKE N'%inconnu%'
      AND TRY_CAST(x.id_expedition AS INT) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dwh.fact_expedition f
                      WHERE f.expedition_id = TRY_CAST(x.id_expedition AS INT))
      AND NOT EXISTS (SELECT 1 FROM etl.quarantaine q
                      WHERE q.table_source = 'expeditions' AND q.cle_source = x.id_expedition);

    SELECT @@ROWCOUNT AS expeditions_mises_en_quarantaine;
END;
GO

/* Retente les expeditions en quarantaine. Contourne volontairement le watermark :
   la ligne est identifiee par sa cle, pas par sa position dans le flux. */
CREATE OR ALTER PROCEDURE etl.usp_retraiter_expeditions
    @max_essais INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT q.quarantaine_id, q.nb_essais, j.*
    INTO #q
    FROM etl.quarantaine q
    CROSS APPLY OPENJSON(q.donnees_brutes) WITH (
        id_expedition     NVARCHAR(20), id_client      NVARCHAR(20),
        id_entrepot       NVARCHAR(20), id_transporteur NVARCHAR(20),
        date_expedition   NVARCHAR(20), poids_kg       NVARCHAR(30),
        volume_m3         NVARCHAR(30), statut         NVARCHAR(50),
        delai_prevu_jours NVARCHAR(10), delai_reel_jours NVARCHAR(10)) j
    WHERE q.table_source = 'expeditions' AND q.statut = 'A_RETRAITER';

    SELECT q.*, m.motif AS nouveau_motif
    INTO #v
    FROM #q q
    CROSS APPLY etl.fn_motif_expedition(q.id_client, q.id_entrepot, q.id_transporteur,
                                        q.date_expedition, q.statut) m;

    BEGIN TRAN;

    INSERT INTO dwh.fact_expedition
        (expedition_id, client_key, entrepot_key, transporteur_key, date_key,
         statut_key, poids_kg, volume_m3, delai_prevu_jours, delai_reel_jours)
    SELECT TRY_CAST(v.id_expedition AS INT), c.client_key, e.entrepot_key,
           t.transporteur_key, d.date_key, st.statut_key,
           TRY_CAST(NULLIF(v.poids_kg, '') AS DECIMAL(10,2)),
           TRY_CAST(NULLIF(v.volume_m3, '') AS DECIMAL(10,2)),
           TRY_CAST(NULLIF(v.delai_prevu_jours, '') AS INT),
           TRY_CAST(NULLIF(v.delai_reel_jours, '') AS INT)
    FROM #v v
    JOIN dwh.dim_client       c  ON c.id_client       = TRY_CAST(v.id_client AS INT)
    JOIN dwh.dim_entrepot     e  ON e.id_entrepot     = TRY_CAST(v.id_entrepot AS INT)
    JOIN dwh.dim_transporteur t  ON t.id_transporteur = TRY_CAST(v.id_transporteur AS INT)
    JOIN dwh.dim_date         d  ON d.date_complete   = TRY_CAST(v.date_expedition AS DATE)
    JOIN dwh.dim_statut       st ON st.statut         = LTRIM(RTRIM(v.statut))
    WHERE v.nouveau_motif IS NULL
      AND NOT EXISTS (SELECT 1 FROM dwh.fact_expedition f
                      WHERE f.expedition_id = TRY_CAST(v.id_expedition AS INT));

    UPDATE q
       SET statut = CASE WHEN v.nouveau_motif IS NULL           THEN 'RETRAITE'
                         WHEN q.nb_essais + 1 >= @max_essais    THEN 'ABANDONNE'
                         ELSE 'A_RETRAITER' END,
           motif              = ISNULL(v.nouveau_motif, q.motif),
           nb_essais          = q.nb_essais + 1,
           date_dernier_essai = SYSUTCDATETIME()
    FROM etl.quarantaine q
    JOIN #v v ON v.quarantaine_id = q.quarantaine_id;

    COMMIT;

    SELECT 'expeditions' AS flux,
           SUM(CASE WHEN nouveau_motif IS NULL THEN 1 ELSE 0 END)                         AS retraites,
           SUM(CASE WHEN nouveau_motif IS NOT NULL AND nb_essais + 1 <  @max_essais THEN 1 ELSE 0 END) AS encore_en_attente,
           SUM(CASE WHEN nouveau_motif IS NOT NULL AND nb_essais + 1 >= @max_essais THEN 1 ELSE 0 END) AS abandonnes
    FROM #v;
END;
GO

/* Retente les evenements de suivi en quarantaine (meme principe). */
CREATE OR ALTER PROCEDURE etl.usp_retraiter_tracking_events
    @max_essais INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT q.quarantaine_id, q.nb_essais,
           TRY_CAST(j.id_evenement AS INT)           AS evenement_id,
           TRY_CAST(j.id_expedition AS INT)          AS expedition_id,
           LTRIM(RTRIM(j.statut))                    AS statut,
           TRY_CAST(j.horodatage AS DATETIME2(0))    AS horodatage
    INTO #q
    FROM etl.quarantaine q
    CROSS APPLY OPENJSON(q.donnees_brutes) WITH (
        id_evenement NVARCHAR(20), id_expedition NVARCHAR(20),
        statut       NVARCHAR(50), horodatage    NVARCHAR(30)) j
    WHERE q.table_source = 'tracking_events' AND q.statut = 'A_RETRAITER';

    SELECT q.*, st.statut_key, d.date_key,
           CASE WHEN f.expedition_id IS NULL THEN N'expedition inconnue'
                WHEN st.statut_key IS NULL   THEN N'statut inconnu'
                WHEN d.date_key IS NULL      THEN N'date inconnue'
           END AS nouveau_motif
    INTO #v
    FROM #q q
    LEFT JOIN dwh.fact_expedition f ON f.expedition_id = q.expedition_id
    LEFT JOIN dwh.dim_statut st     ON st.statut       = q.statut
    LEFT JOIN dwh.dim_date d        ON d.date_complete = CAST(q.horodatage AS DATE);

    BEGIN TRAN;

    INSERT INTO dwh.fact_suivi_evenement (evenement_id, expedition_id, statut_key, date_key, horodatage)
    SELECT v.evenement_id, v.expedition_id, v.statut_key, v.date_key, v.horodatage
    FROM #v v
    WHERE v.nouveau_motif IS NULL
      AND NOT EXISTS (SELECT 1 FROM dwh.fact_suivi_evenement t WHERE t.evenement_id = v.evenement_id);

    UPDATE q
       SET statut = CASE WHEN v.nouveau_motif IS NULL           THEN 'RETRAITE'
                         WHEN q.nb_essais + 1 >= @max_essais    THEN 'ABANDONNE'
                         ELSE 'A_RETRAITER' END,
           motif              = ISNULL(v.nouveau_motif, q.motif),
           nb_essais          = q.nb_essais + 1,
           date_dernier_essai = SYSUTCDATETIME()
    FROM etl.quarantaine q
    JOIN #v v ON v.quarantaine_id = q.quarantaine_id;

    COMMIT;

    SELECT 'tracking_events' AS flux,
           SUM(CASE WHEN nouveau_motif IS NULL THEN 1 ELSE 0 END)                         AS retraites,
           SUM(CASE WHEN nouveau_motif IS NOT NULL AND nb_essais + 1 <  @max_essais THEN 1 ELSE 0 END) AS encore_en_attente,
           SUM(CASE WHEN nouveau_motif IS NOT NULL AND nb_essais + 1 >= @max_essais THEN 1 ELSE 0 END) AS abandonnes
    FROM #v;
END;
GO

/* Orchestration : les parents d'abord. Un evenement ne peut etre retraite
   qu'une fois son expedition chargee. */
CREATE OR ALTER PROCEDURE etl.usp_retraitement
AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.usp_quarantaine_expeditions;
    EXEC etl.usp_retraiter_expeditions;
    EXEC etl.usp_retraiter_tracking_events;
END;
GO
