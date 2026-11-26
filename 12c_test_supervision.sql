/* TransLog Maroc (societe FICTIVE) - Test de la supervision. A executer bloc par bloc
   (selectionner le bloc puis F5). */
USE translog_dw;
GO

-- 1) Quels flux ont deja ecrit dans le journal ?
SELECT package, statut, COUNT(*) AS nb, MAX(date_log) AS derniere
FROM etl.log_execution
GROUP BY package, statut;

-- 2) Une execution journalisee du flux P4 (partie base de donnees)
EXEC etl.usp_run_tracking_events;

-- 3) Une execution fraiche des controles qualite
EXEC etl.usp_run_controles;

-- 4) Sante des flux, puis tableau de sante complet
SELECT * FROM etl.v_sante_flux;
SELECT * FROM etl.v_tableau_sante;

-- 5) Verification sans echec, puis avec echec (comportement du job)
EXEC etl.usp_verifier_sante @echouer_si_rouge = 0;
EXEC etl.usp_verifier_sante;

-- 6) Simulation d'une panne du flux P4
EXEC etl.usp_log_execution @package = N'P4_Tracking', @statut = 'ECHEC',
     @message = N'Test : API indisponible (code de sortie 2)';
SELECT flux, dernier_statut, feu, message FROM etl.v_sante_flux;

-- 7) Retour a la normale : une nouvelle execution reussie
EXEC etl.usp_run_tracking_events;
SELECT flux, dernier_statut, feu FROM etl.v_sante_flux;

-- 8) Historique des alertes
SELECT TOP (20) date_alerte, categorie, composant, niveau, detail
FROM etl.alerte
ORDER BY alerte_id DESC;
