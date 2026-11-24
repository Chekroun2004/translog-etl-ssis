/* P4 - Execution manuelle du flux, avant de l'automatiser dans SSIS.
   Etape 0 (PowerShell, depuis C:\TransLog) :
       $env:TRANSLOG_API_KEY = "cle-de-demo"
       uvicorn api.mock_api:app --port 8000          (fenetre 1, laisser ouverte)
       python api\ingest_tracking.py --after-id <WM>  (fenetre 2) ou <WM> = resultat de la requete 1 */
USE translog_dw;
GO

-- 1) Watermark actuel
SELECT derniere_valeur AS wm FROM etl.watermark WHERE nom_flux = 'tracking_events';

-- 2) Chargement du CSV produit par Python (vider le staging d'abord : il ne garde que le dernier lot)
TRUNCATE TABLE stg.tracking_events;
BULK INSERT stg.tracking_events FROM 'C:\TransLog\data\tracking_events.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', CODEPAGE = '65001');

-- 3) Chargement vers le DWH
EXEC etl.usp_load_tracking_events;

-- 4) Controles
SELECT COUNT(*) AS nb_evenements, MIN(evenement_id) AS min_id, MAX(evenement_id) AS max_id
FROM dwh.fact_suivi_evenement;

SELECT motif, COUNT(*) AS nb FROM etl.rejet
WHERE table_source = 'tracking_events' GROUP BY motif;

SELECT s.statut, COUNT(*) AS nb
FROM dwh.fact_suivi_evenement e JOIN dwh.dim_statut s ON s.statut_key = e.statut_key
GROUP BY s.statut ORDER BY nb DESC;
