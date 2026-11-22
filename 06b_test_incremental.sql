/* TransLog Maroc (societe FICTIVE) - Test du chargement incremental.
   Simule une nouvelle livraison de 4 expeditions dans le staging :
   3 valides (3001 a 3003) et 1 avec un client inconnu (3004). */
USE translog_dw;
GO

-- 1) Etat avant
SELECT COUNT(*) AS nb_fait
FROM dwh.fact_expedition;
SELECT * FROM etl.watermark;

-- 2) Nouvelle livraison
INSERT INTO stg.expeditions
    (id_expedition, id_client, id_entrepot, id_transporteur, date_expedition,
     poids_kg, volume_m3, statut, delai_prevu_jours, delai_reel_jours)
VALUES
    ('3001', '7',   '2', '1', '2026-11-20', '512.0', '2.10', 'Livre',      '2', '3'),
    ('3002', '12',  '1', '3', '2026-11-20', '230.5', '1.05', 'En transit', '3', ''),
    ('3003', '45',  '4', '2', '2026-11-21', '900.0', '4.80', 'Livre',      '1', '1'),
    ('3004', '999', '1', '1', '2026-11-21', '100.0', '0.50', 'Livre',      '1', '1');

-- 3) Premier passage
EXEC etl.usp_load_fact_expedition_incr;

-- 4) Deuxieme passage (idempotence)
EXEC etl.usp_load_fact_expedition_incr;

-- 5) Controles
SELECT COUNT(*) AS nb_faits FROM dwh.fact_expedition;
SELECT expedition_id, delai_reel_jours
FROM dwh.fact_expedition WHERE expedition_id > 3000;
