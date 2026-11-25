/* TransLog Maroc (societe FICTIVE) - Test de la quarantaine et du retraitement.
   Prerequis : stg.tracking_events contient le lot complet (ingestion --after-id 0 puis
   BULK INSERT, SANS executer la procedure). A executer bloc par bloc. */
USE translog_dw;
GO

-- 1) Reprise des 7 evenements deja rejetes : ils passent en quarantaine, sans doublon dans etl.rejet
EXEC etl.usp_load_tracking_events;

-- 2) Mise en quarantaine des expeditions rejetees
EXEC etl.usp_quarantaine_expeditions;

-- 3) Contenu de la quarantaine
SELECT table_source, cle_source, motif, statut, nb_essais, donnees_brutes
FROM etl.quarantaine
ORDER BY table_source, TRY_CAST(cle_source AS INT);

-- 4) Simulation : les clients 999 et 9999 arrivent enfin dans la source clients
INSERT INTO stg.clients (id_client, nom, ville, adresse)
SELECT v.id_client, v.nom, v.ville, v.adresse
FROM (VALUES ('999',  'Client 999',  'Rabat',   '1 avenue Test, Rabat'),
             ('9999', 'Client 9999', 'Tanger',  '2 rue Test, Tanger')) v (id_client, nom, ville, adresse)
WHERE NOT EXISTS (SELECT 1 FROM stg.clients c WHERE c.id_client = v.id_client);
EXEC etl.usp_load_dim_client;

-- 5) Retraitement (expeditions puis evenements)
EXEC etl.usp_retraitement;

-- 6) Etat final
SELECT table_source, statut, COUNT(*) AS nb
FROM etl.quarantaine
GROUP BY table_source, statut
ORDER BY table_source, statut;

SELECT table_source, cle_source, motif, statut, nb_essais
FROM etl.quarantaine
ORDER BY table_source, TRY_CAST(cle_source AS INT);
