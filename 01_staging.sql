/* TransLog Maroc (societe FICTIVE) - Etape 1 : staging
   Prerequis : les 4 CSV sont dans C:\TransLog\data\
   Les colonnes du staging sont en NVARCHAR : on charge TOUT tel quel,
   les controles qualite viennent apres (projet P5). */

IF DB_ID('translog_dw') IS NULL
    CREATE DATABASE translog_dw;
GO

USE translog_dw;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dwh') IS NULL EXEC('CREATE SCHEMA dwh');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

DROP TABLE IF EXISTS stg.expeditions, stg.clients, stg.entrepots, stg.transporteurs;
GO

CREATE TABLE stg.entrepots (
    id_entrepot NVARCHAR(20), code NVARCHAR(20), nom NVARCHAR(100), ville NVARCHAR(100));
CREATE TABLE stg.transporteurs (
    id_transporteur NVARCHAR(20), nom NVARCHAR(100), type NVARCHAR(50));
CREATE TABLE stg.clients (
    id_client NVARCHAR(20), nom NVARCHAR(100), ville NVARCHAR(100), adresse NVARCHAR(200));
CREATE TABLE stg.expeditions (
    id_expedition NVARCHAR(20), id_client NVARCHAR(20), id_entrepot NVARCHAR(20),
    id_transporteur NVARCHAR(20), date_expedition NVARCHAR(20), poids_kg NVARCHAR(30),
    volume_m3 NVARCHAR(30), statut NVARCHAR(50), delai_prevu_jours NVARCHAR(10),
    delai_reel_jours NVARCHAR(10));
GO

BULK INSERT stg.entrepots FROM 'C:\TransLog\data\entrepots.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');
BULK INSERT stg.transporteurs FROM 'C:\TransLog\data\transporteurs.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');
BULK INSERT stg.clients FROM 'C:\TransLog\data\clients.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');
BULK INSERT stg.expeditions FROM 'C:\TransLog\data\expeditions.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');
GO

/* Controle : nombre de lignes attendu = 8 / 6 / 60 / 3003 */
SELECT 'entrepots' AS table_, COUNT(*) AS nb FROM stg.entrepots
UNION ALL SELECT 'transporteurs', COUNT(*) FROM stg.transporteurs
UNION ALL SELECT 'clients', COUNT(*) FROM stg.clients
UNION ALL SELECT 'expeditions', COUNT(*) FROM stg.expeditions;
GO
