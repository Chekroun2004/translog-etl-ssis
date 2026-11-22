/* TransLog Maroc (societe FICTIVE) - Chargement des dimensions (staging -> DWH).
   MERGE rejouable : insere les nouveautes, met a jour ce qui a change, ne supprime rien.
   Les conversions utilisent TRY_CAST : une valeur non numerique est ecartee, pas bloquante. */
USE translog_dw;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_entrepot AS
BEGIN
    SET NOCOUNT ON;
    WITH src AS (
        SELECT TRY_CAST(id_entrepot AS INT) AS id_entrepot, code, nom, ville,
               ROW_NUMBER() OVER (PARTITION BY TRY_CAST(id_entrepot AS INT)
                                  ORDER BY (SELECT NULL)) AS rn
        FROM stg.entrepots
        WHERE TRY_CAST(id_entrepot AS INT) IS NOT NULL
    )
    MERGE dwh.dim_entrepot AS t
    USING (SELECT id_entrepot, code, nom, ville FROM src WHERE rn = 1) AS s
       ON t.id_entrepot = s.id_entrepot
    WHEN MATCHED AND (ISNULL(t.code,'')  <> ISNULL(s.code,'')
                   OR ISNULL(t.nom,'')   <> ISNULL(s.nom,'')
                   OR ISNULL(t.ville,'') <> ISNULL(s.ville,''))
        THEN UPDATE SET t.code = s.code, t.nom = s.nom, t.ville = s.ville
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_entrepot, code, nom, ville)
             VALUES (s.id_entrepot, s.code, s.nom, s.ville);
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_transporteur AS
BEGIN
    SET NOCOUNT ON;
    WITH src AS (
        SELECT TRY_CAST(id_transporteur AS INT) AS id_transporteur, nom, [type],
               ROW_NUMBER() OVER (PARTITION BY TRY_CAST(id_transporteur AS INT)
                                  ORDER BY (SELECT NULL)) AS rn
        FROM stg.transporteurs
        WHERE TRY_CAST(id_transporteur AS INT) IS NOT NULL
    )
    MERGE dwh.dim_transporteur AS t
    USING (SELECT id_transporteur, nom, [type] FROM src WHERE rn = 1) AS s
       ON t.id_transporteur = s.id_transporteur
    WHEN MATCHED AND (ISNULL(t.nom,'')    <> ISNULL(s.nom,'')
                   OR ISNULL(t.[type],'') <> ISNULL(s.[type],''))
        THEN UPDATE SET t.nom = s.nom, t.[type] = s.[type]
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_transporteur, nom, [type])
             VALUES (s.id_transporteur, s.nom, s.[type]);
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_client AS
BEGIN
    SET NOCOUNT ON;
    WITH src AS (
        SELECT TRY_CAST(id_client AS INT) AS id_client, nom, ville, adresse,
               ROW_NUMBER() OVER (PARTITION BY TRY_CAST(id_client AS INT)
                                  ORDER BY (SELECT NULL)) AS rn
        FROM stg.clients
        WHERE TRY_CAST(id_client AS INT) IS NOT NULL
    )
    MERGE dwh.dim_client AS t
    USING (SELECT id_client, nom, ville, adresse FROM src WHERE rn = 1) AS s
       ON t.id_client = s.id_client
    WHEN MATCHED AND (ISNULL(t.nom,'')     <> ISNULL(s.nom,'')
                   OR ISNULL(t.ville,'')   <> ISNULL(s.ville,'')
                   OR ISNULL(t.adresse,'') <> ISNULL(s.adresse,''))
        THEN UPDATE SET t.nom = s.nom, t.ville = s.ville, t.adresse = s.adresse
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (id_client, nom, ville, adresse)
             VALUES (s.id_client, s.nom, s.ville, s.adresse);
END;
GO

/* Le statut est un referentiel : liste fixe. Une valeur inconnue dans les donnees
   n'entre pas dans la dimension, elle sera rejetee au chargement des faits. */
CREATE OR ALTER PROCEDURE etl.usp_load_dim_statut AS
BEGIN
    SET NOCOUNT ON;
    MERGE dwh.dim_statut AS t
    USING (VALUES ('Annule'), ('En preparation'), ('En transit'),
                  ('Livre'), ('Retourne')) AS s(statut)
       ON t.statut = s.statut
    WHEN NOT MATCHED BY TARGET
        THEN INSERT (statut) VALUES (s.statut);
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dimensions AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.usp_load_dim_entrepot;
    EXEC etl.usp_load_dim_transporteur;
    EXEC etl.usp_load_dim_client;
    EXEC etl.usp_load_dim_statut;
END;
GO
