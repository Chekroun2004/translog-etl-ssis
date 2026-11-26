/* TransLog Maroc (societe FICTIVE) - P6 : supervision des flux.
   4 indicateurs : statut de la derniere execution, fraicheur (heures depuis le dernier
   succes), rejets, qualite (regles KO, lignes abandonnees en quarantaine).
   Resume en feu VERT / ORANGE / ROUGE par composant (etl.v_tableau_sante).
   Alerte : etl.usp_verifier_sante ecrit chaque anomalie dans etl.alerte et echoue
   (THROW) s'il y a du ROUGE ; le job SQL Server Agent qui la lance apparait alors en echec.
   Le canal (e-mail via Database Mail) pourra etre branche sur le job sans rien reecrire.
   Prerequis : 07_log_execution.sql, 10_qualite.sql, 11_quarantaine.sql. */
USE translog_dw;
GO

/* 1) Le journal accepte aussi le nombre de rejets (colonne ajoutee, rien de casse). */
IF COL_LENGTH('etl.log_execution', 'lignes_rejetees') IS NULL
    ALTER TABLE etl.log_execution ADD lignes_rejetees INT NULL;
GO

/* Nouveau parametre en DERNIERE position : les appels existants (package P3) restent valides. */
CREATE OR ALTER PROCEDURE etl.usp_log_execution
    @package           NVARCHAR(100),
    @statut            VARCHAR(10),
    @lignes_chargees   INT = NULL,
    @ancien_watermark  INT = NULL,
    @nouveau_watermark INT = NULL,
    @message           NVARCHAR(4000) = NULL,
    @lignes_rejetees   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.log_execution
        (package, statut, lignes_chargees, ancien_watermark, nouveau_watermark, message, lignes_rejetees)
    VALUES
        (@package, @statut, @lignes_chargees, @ancien_watermark, @nouveau_watermark, @message, @lignes_rejetees);
END;
GO

/* 2) Ce qu'on attend de chaque flux : frequence et taux de rejet tolere. */
IF OBJECT_ID('etl.flux_supervision') IS NULL
CREATE TABLE etl.flux_supervision (
    flux             NVARCHAR(100) NOT NULL PRIMARY KEY,   -- = etl.log_execution.package
    description      NVARCHAR(200) NOT NULL,
    frequence_heures INT           NOT NULL CHECK (frequence_heures > 0),
    seuil_rejets_pct DECIMAL(5,2)  NOT NULL DEFAULT 1.00,
    actif            BIT           NOT NULL DEFAULT 1
);
GO

INSERT INTO etl.flux_supervision (flux, description, frequence_heures, seuil_rejets_pct)
SELECT v.flux, v.description, v.frequence_heures, v.seuil_rejets_pct
FROM (VALUES
    (N'P3_Incremental', N'Chargement incremental des expeditions (job Agent 02h00)', 24, 1.00),
    (N'P4_Tracking',    N'Evenements de suivi issus de l''API REST',                24, 1.00)
) v (flux, description, frequence_heures, seuil_rejets_pct)
WHERE NOT EXISTS (SELECT 1 FROM etl.flux_supervision f WHERE f.flux = v.flux);
GO

/* 3) Historique des alertes : une ligne par anomalie et par verification. */
IF OBJECT_ID('etl.alerte') IS NULL
CREATE TABLE etl.alerte (
    alerte_id       INT IDENTITY(1,1) PRIMARY KEY,
    verification_id UNIQUEIDENTIFIER NOT NULL,
    date_alerte     DATETIME2(0)     NOT NULL DEFAULT SYSUTCDATETIME(),
    categorie       NVARCHAR(30)     NOT NULL,
    composant       NVARCHAR(100)    NOT NULL,
    niveau          NVARCHAR(10)     NOT NULL CHECK (niveau IN ('ORANGE', 'ROUGE')),
    detail          NVARCHAR(400)    NULL
);
GO

/* 4) Sante de chaque flux. Les dates du journal sont en UTC (SYSUTCDATETIME).
   ROUGE  : jamais reussi, derniere execution en ECHEC, ou aucun succes depuis 2 periodes.
   ORANGE : aucun succes depuis 1 periode (retard), ou taux de rejet au-dessus du seuil.
   VERT   : sinon. */
CREATE OR ALTER VIEW etl.v_sante_flux
AS
WITH derniere AS (
    SELECT package, statut, lignes_chargees, lignes_rejetees, message, date_log,
           ROW_NUMBER() OVER (PARTITION BY package ORDER BY date_log DESC, log_id DESC) AS rn
    FROM etl.log_execution
),
succes AS (
    SELECT package, MAX(date_log) AS date_dernier_succes
    FROM etl.log_execution
    WHERE statut = 'SUCCES'
    GROUP BY package
),
calc AS (
    SELECT f.flux, f.frequence_heures, f.seuil_rejets_pct,
           d.statut   AS dernier_statut,
           d.date_log AS date_derniere_execution,
           s.date_dernier_succes,
           DATEDIFF(MINUTE, s.date_dernier_succes, SYSUTCDATETIME()) AS minutes_depuis_succes,
           ISNULL(d.lignes_chargees, 0) AS lignes_chargees,
           ISNULL(d.lignes_rejetees, 0) AS lignes_rejetees,
           d.message
    FROM etl.flux_supervision f
    LEFT JOIN derniere d ON d.package = f.flux AND d.rn = 1
    LEFT JOIN succes s   ON s.package = f.flux
    WHERE f.actif = 1
)
SELECT flux, dernier_statut, date_derniere_execution, date_dernier_succes,
       CAST(minutes_depuis_succes / 60.0 AS DECIMAL(10,1)) AS heures_depuis_succes,
       frequence_heures, lignes_chargees, lignes_rejetees,
       CAST(CASE WHEN lignes_chargees + lignes_rejetees = 0 THEN 0
                 ELSE 100.0 * lignes_rejetees / (lignes_chargees + lignes_rejetees) END
            AS DECIMAL(5,2)) AS taux_rejet_pct,
       message,
       CASE
         WHEN date_dernier_succes IS NULL                        THEN 'ROUGE'
         WHEN dernier_statut = 'ECHEC'                           THEN 'ROUGE'
         WHEN minutes_depuis_succes > frequence_heures * 60 * 2  THEN 'ROUGE'
         WHEN minutes_depuis_succes > frequence_heures * 60      THEN 'ORANGE'
         WHEN lignes_chargees + lignes_rejetees > 0
          AND 100.0 * lignes_rejetees / (lignes_chargees + lignes_rejetees) > seuil_rejets_pct
                                                                 THEN 'ORANGE'
         ELSE 'VERT'
       END AS feu
FROM calc;
GO

/* 5) Tableau de sante : flux + qualite + quarantaine, une ligne par composant. */
CREATE OR ALTER VIEW etl.v_tableau_sante
AS
SELECT N'flux' AS categorie, flux AS composant, feu,
       CONCAT(N'dernier statut : ', ISNULL(dernier_statut, N'aucun'),
              N' ; dernier succes il y a ',
              ISNULL(CAST(heures_depuis_succes AS NVARCHAR(20)), N'?'), N' h',
              N' ; rejets : ', taux_rejet_pct, N' %') AS detail
FROM etl.v_sante_flux

UNION ALL

SELECT N'qualite', N'regles (derniere execution)',
       CASE WHEN SUM(CASE WHEN cr.statut = 'ERREUR'
                           OR (cr.statut = 'KO' AND r.gravite = 'BLOQUANT') THEN 1 ELSE 0 END) > 0 THEN 'ROUGE'
            WHEN SUM(CASE WHEN cr.statut = 'KO' THEN 1 ELSE 0 END) > 0 THEN 'ORANGE'
            ELSE 'VERT' END,
       CONCAT(SUM(CASE WHEN cr.statut = 'KO' AND r.gravite = 'BLOQUANT' THEN 1 ELSE 0 END), N' bloquante(s) KO ; ',
              SUM(CASE WHEN cr.statut = 'KO' AND r.gravite = 'AVERTISSEMENT' THEN 1 ELSE 0 END), N' avertissement(s) KO ; ',
              SUM(CASE WHEN cr.statut = 'ERREUR' THEN 1 ELSE 0 END), N' en erreur')
FROM etl.controle_resultat cr
JOIN etl.regle_qualite r ON r.regle_id = cr.regle_id
WHERE cr.execution_id = (SELECT TOP (1) execution_id FROM etl.controle_resultat ORDER BY resultat_id DESC)

UNION ALL

SELECT N'quarantaine', table_source,
       CASE WHEN SUM(CASE WHEN statut = 'ABANDONNE' THEN 1 ELSE 0 END) > 0 THEN 'ORANGE' ELSE 'VERT' END,
       CONCAT(SUM(CASE WHEN statut = 'A_RETRAITER' THEN 1 ELSE 0 END), N' a retraiter ; ',
              SUM(CASE WHEN statut = 'ABANDONNE' THEN 1 ELSE 0 END), N' abandonnee(s) ; ',
              SUM(CASE WHEN statut = 'RETRAITE' THEN 1 ELSE 0 END), N' retraitee(s)')
FROM etl.quarantaine
GROUP BY table_source;
GO

/* 6) Verification : historise les anomalies, affiche le tableau, echoue s'il y a du ROUGE. */
CREATE OR ALTER PROCEDURE etl.usp_verifier_sante
    @echouer_si_rouge BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @verification_id UNIQUEIDENTIFIER = NEWID(), @nb_rouge INT, @msg NVARCHAR(2048);

    SELECT categorie, composant, feu, detail
    INTO #sante
    FROM etl.v_tableau_sante;

    INSERT INTO etl.alerte (verification_id, categorie, composant, niveau, detail)
    SELECT @verification_id, categorie, composant, feu, detail
    FROM #sante
    WHERE feu <> 'VERT';

    SELECT categorie, composant, feu, detail
    FROM #sante
    ORDER BY CASE feu WHEN 'ROUGE' THEN 0 WHEN 'ORANGE' THEN 1 ELSE 2 END, categorie, composant;

    SELECT @nb_rouge = COUNT(*) FROM #sante WHERE feu = 'ROUGE';

    IF @nb_rouge > 0 AND @echouer_si_rouge = 1
    BEGIN
        SET @msg = CONCAT(@nb_rouge, N' composant(s) au ROUGE. Detail : SELECT * FROM etl.alerte WHERE verification_id = ''',
                          CAST(@verification_id AS NVARCHAR(36)), N'''');
        THROW 50100, @msg, 1;
    END;
END;
GO

/* 7) Flux P4 journalise : la partie base de donnees du flux, avec log SUCCES ou ECHEC.
   (Le package SSIS P4 fera le meme travail en ajoutant l'appel a l'API.) */
CREATE OR ALTER PROCEDURE etl.usp_run_tracking_events
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @r TABLE (lignes_chargees INT, lignes_rejetees INT,
                      ancien_watermark INT, nouveau_watermark INT);
    DECLARE @msg NVARCHAR(4000);

    BEGIN TRY
        INSERT INTO @r EXEC etl.usp_load_tracking_events;

        INSERT INTO etl.log_execution
            (package, statut, lignes_chargees, lignes_rejetees, ancien_watermark, nouveau_watermark)
        SELECT N'P4_Tracking', 'SUCCES', lignes_chargees, lignes_rejetees, ancien_watermark, nouveau_watermark
        FROM @r;

        SELECT * FROM @r;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        EXEC etl.usp_log_execution @package = N'P4_Tracking', @statut = 'ECHEC', @message = @msg;
        THROW;
    END CATCH;
END;
GO
