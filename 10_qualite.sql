/* TransLog Maroc (societe FICTIVE) - P5 : framework de controles qualite.
   Principe : les regles metier sont des donnees (etl.regle_qualite), pas du code.
   Chaque regle est une requete qui renvoie UNE colonne "cle" : les lignes en defaut.
   0 ligne renvoyee = regle respectee.
   Ces controles s'executent APRES le chargement, sur le DWH. Les controles techniques
   d'entree (typage, doublon, cle inconnue) restent dans les procedures de chargement. */
USE translog_dw;
GO

IF OBJECT_ID('etl.regle_qualite') IS NULL
CREATE TABLE etl.regle_qualite (
    regle_id    INT IDENTITY(1,1) PRIMARY KEY,
    code        NVARCHAR(50)  NOT NULL UNIQUE,
    flux        NVARCHAR(50)  NOT NULL,
    dimension   NVARCHAR(30)  NOT NULL
        CHECK (dimension IN ('completude','validite','unicite','integrite','plausibilite')),
    gravite     NVARCHAR(15)  NOT NULL CHECK (gravite IN ('BLOQUANT','AVERTISSEMENT')),
    description NVARCHAR(200) NOT NULL,
    requete_sql NVARCHAR(MAX) NOT NULL,
    actif       BIT NOT NULL DEFAULT 1
);
GO

/* Une ligne par regle et par execution : c'est l'historique de la qualite. */
IF OBJECT_ID('etl.controle_resultat') IS NULL
CREATE TABLE etl.controle_resultat (
    resultat_id   INT IDENTITY(1,1) PRIMARY KEY,
    execution_id  UNIQUEIDENTIFIER NOT NULL,
    regle_id      INT NOT NULL REFERENCES etl.regle_qualite(regle_id),
    date_controle DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    nb_lignes_ko  INT NULL,
    statut        NVARCHAR(10) NOT NULL CHECK (statut IN ('OK','KO','ERREUR')),
    message       NVARCHAR(4000) NULL
);
GO

/* Les cles en defaut, pour savoir QUELLES lignes corriger. */
IF OBJECT_ID('etl.controle_anomalie') IS NULL
CREATE TABLE etl.controle_anomalie (
    resultat_id INT NOT NULL REFERENCES etl.controle_resultat(resultat_id),
    cle         NVARCHAR(100) NOT NULL
);
GO

/* Executeur generique. Une regle en erreur (requete cassee) est notee ERREUR
   et n'arrete pas les autres. Securite : seul le proprietaire du schema etl doit
   pouvoir ecrire dans etl.regle_qualite (les requetes y sont executees telles quelles). */
CREATE OR ALTER PROCEDURE etl.usp_run_controles
    @flux NVARCHAR(50) = NULL   -- NULL = toutes les regles actives
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @execution_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @regle_id INT, @sql NVARCHAR(MAX), @nb INT, @resultat_id INT;

    CREATE TABLE #ko (cle NVARCHAR(100));

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT regle_id, requete_sql
        FROM etl.regle_qualite
        WHERE actif = 1 AND (@flux IS NULL OR flux = @flux)
        ORDER BY regle_id;

    OPEN c;
    FETCH NEXT FROM c INTO @regle_id, @sql;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        TRUNCATE TABLE #ko;
        BEGIN TRY
            INSERT INTO #ko (cle) EXEC sp_executesql @sql;
            SET @nb = (SELECT COUNT(*) FROM #ko);

            INSERT INTO etl.controle_resultat (execution_id, regle_id, nb_lignes_ko, statut)
            VALUES (@execution_id, @regle_id, @nb, CASE WHEN @nb = 0 THEN 'OK' ELSE 'KO' END);
            SET @resultat_id = SCOPE_IDENTITY();

            INSERT INTO etl.controle_anomalie (resultat_id, cle)
            SELECT @resultat_id, cle FROM #ko;
        END TRY
        BEGIN CATCH
            INSERT INTO etl.controle_resultat (execution_id, regle_id, nb_lignes_ko, statut, message)
            VALUES (@execution_id, @regle_id, NULL, 'ERREUR', ERROR_MESSAGE());
        END CATCH;

        FETCH NEXT FROM c INTO @regle_id, @sql;
    END;
    CLOSE c;
    DEALLOCATE c;

    /* Rapport de l'execution : erreurs d'abord, puis KO, puis OK. */
    SELECT r.code, r.dimension, r.gravite, cr.statut, cr.nb_lignes_ko, cr.message
    FROM etl.controle_resultat cr
    JOIN etl.regle_qualite r ON r.regle_id = cr.regle_id
    WHERE cr.execution_id = @execution_id
    ORDER BY CASE cr.statut WHEN 'ERREUR' THEN 0 WHEN 'KO' THEN 1 ELSE 2 END, r.regle_id;
END;
GO

/* Regles initiales. Une regle = une dimension = un motif clair. */
INSERT INTO etl.regle_qualite (code, flux, dimension, gravite, description, requete_sql)
SELECT v.code, v.flux, v.dimension, v.gravite, v.description, v.requete_sql
FROM (VALUES
  (N'EXP_POIDS_NON_POSITIF', N'expeditions', N'plausibilite', N'BLOQUANT',
   N'Poids negatif ou nul',
   N'SELECT CAST(expedition_id AS NVARCHAR(100)) FROM dwh.fact_expedition WHERE poids_kg <= 0'),
  (N'EXP_POIDS_ABSENT', N'expeditions', N'completude', N'BLOQUANT',
   N'Poids non renseigne',
   N'SELECT CAST(expedition_id AS NVARCHAR(100)) FROM dwh.fact_expedition WHERE poids_kg IS NULL'),
  (N'EXP_VOLUME_ABSENT', N'expeditions', N'completude', N'AVERTISSEMENT',
   N'Volume non renseigne',
   N'SELECT CAST(expedition_id AS NVARCHAR(100)) FROM dwh.fact_expedition WHERE volume_m3 IS NULL'),
  /* Seuil metier : au-dela de 30 t, une expedition routiere est suspecte (hypothese generale,
     la charge utile depend du vehicule). Seuil verifie contre la mediane et le p99 des poids. */
  (N'EXP_POIDS_EXTREME', N'expeditions', N'plausibilite', N'AVERTISSEMENT',
   N'Poids superieur a 30 tonnes',
   N'SELECT CAST(expedition_id AS NVARCHAR(100)) FROM dwh.fact_expedition WHERE poids_kg > 30000')
) v (code, flux, dimension, gravite, description, requete_sql)
WHERE NOT EXISTS (SELECT 1 FROM etl.regle_qualite r WHERE r.code = v.code);
GO

/* Execution :
EXEC etl.usp_run_controles;                       -- toutes les regles
EXEC etl.usp_run_controles @flux = 'expeditions'; -- un seul flux

-- Quelles lignes sont en defaut pour une regle ?
SELECT a.cle
FROM etl.controle_anomalie a
JOIN etl.controle_resultat cr ON cr.resultat_id = a.resultat_id
JOIN etl.regle_qualite r      ON r.regle_id = cr.regle_id
WHERE r.code = 'EXP_POIDS_NON_POSITIF'
  AND cr.execution_id = (SELECT TOP 1 execution_id FROM etl.controle_resultat
                         ORDER BY resultat_id DESC);
*/
