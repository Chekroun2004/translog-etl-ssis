USE translog_dw;
GO
DROP TABLE IF EXISTS dwh.fact_expedition, dwh.dim_client, dwh.dim_entrepot,
                     dwh.dim_transporteur, dwh.dim_statut, dwh.dim_date;
GO
CREATE TABLE dwh.dim_client (
    client_key INT IDENTITY(1,1) PRIMARY KEY,
    id_client  INT NOT NULL,
    nom NVARCHAR(100), ville NVARCHAR(100), adresse NVARCHAR(200));

CREATE TABLE dwh.dim_entrepot (
    entrepot_key INT IDENTITY(1,1) PRIMARY KEY,
    id_entrepot  INT NOT NULL,
    code NVARCHAR(20), nom NVARCHAR(100), ville NVARCHAR(100));

CREATE TABLE dwh.dim_transporteur (
    transporteur_key INT IDENTITY(1,1) PRIMARY KEY,
    id_transporteur  INT NOT NULL,
    nom NVARCHAR(100), type NVARCHAR(50));

CREATE TABLE dwh.dim_statut (
    statut_key INT IDENTITY(1,1) PRIMARY KEY,
    statut NVARCHAR(50) NOT NULL);

CREATE TABLE dwh.dim_date (
    date_key      INT PRIMARY KEY,   -- format AAAAMMJJ
    date_complete DATE NOT NULL,
    annee INT, mois INT, jour INT);

CREATE TABLE dwh.fact_expedition (
    expedition_id     INT NOT NULL PRIMARY KEY,   -- degenerate dimension
    client_key        INT NOT NULL REFERENCES dwh.dim_client(client_key),
    entrepot_key      INT NOT NULL REFERENCES dwh.dim_entrepot(entrepot_key),
    transporteur_key  INT NOT NULL REFERENCES dwh.dim_transporteur(transporteur_key),
    date_key          INT NOT NULL REFERENCES dwh.dim_date(date_key),
    statut_key        INT NOT NULL REFERENCES dwh.dim_statut(statut_key),
    poids_kg          DECIMAL(10,2),
    volume_m3         DECIMAL(10,2),
    delai_prevu_jours INT,
    delai_reel_jours  INT);
GO
SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('dwh') ORDER BY name;