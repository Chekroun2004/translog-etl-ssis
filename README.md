# TransLog Maroc : pipeline ETL SSIS vers Data Warehouse

Projet personnel d'apprentissage sur un cas logistique **fictif** (transport routier de marchandises). Toutes les données sont synthétiques et générées par un script reproductible.

## Objectif

Charger des fichiers CSV (expéditions, clients, entrepôts, transporteurs) dans un Data Warehouse SQL Server en schéma en étoile, avec :

- un chargement **rejouable** (relancer donne le même résultat) ;
- une **traçabilité des lignes rejetées**, avec leur motif.

## Architecture

```
CSV (data/)
   |  SSIS : Flat File Source -> OLE DB Destination (TRUNCATE avant chargement)
   v
stg.*   staging : tout en NVARCHAR, rien n'est corrigé
   |  T-SQL MERGE : dimensions (etl.usp_load_dimensions)
   |  SSIS Data Flow : Conditional Split + 5 Lookups : table de faits
   v
dwh.*   schéma en étoile
   |  T-SQL : etl.usp_log_rejets_expeditions
   v
etl.rejet   lignes écartées + motif
```

Schéma en étoile :

```
dim_client  dim_entrepot  dim_transporteur
      \          |          /
       \         |         /
        fact_expedition
       /         |         \
      /          |          \
dim_date                dim_statut
```

La table de faits a pour grain **une ligne par expédition** (`expedition_id` en dimension dégénérée). Les mesures sont le poids, le volume et les délais prévu et réel.

## Contenu du dépôt

```
gen_translog.py          génération des CSV synthétiques (graine fixe)
data/                    CSV générés (avec anomalies volontaires)
01_staging.sql           base, schémas, tables de staging, chargement initial
02_schema_dwh.sql        tables du schéma en étoile
02b_load_dim_date.sql    alimentation de dim_date (année 2026)
03_load_dimensions.sql   procédures MERGE des dimensions
04_rejets.sql            table etl.rejet et procédure de journalisation
05_scd2_client.sql       dimension client historisée (SCD type 2)
06_incremental_expeditions.sql  chargement incrémental de la table de faits (watermark)
06b_test_incremental.sql        scénario de test du chargement incrémental
07_log_execution.sql     journal d'exécution des packages (etl.log_execution)
08_agent_job.sql         job SQL Server Agent qui lance P3_Incremental chaque nuit
09_tracking_events.sql   P4 : staging, table de faits des événements de suivi, procédure de chargement
09b_run_tracking_manual.sql  P4 : exécution manuelle et contrôles
api/                     P4 : API REST simulée (FastAPI) et script d'ingestion
tests/                   tests Pytest de l'ingestion API
ssis/TransLog_ETL/       projet SSIS (package P2_Charge_Staging.dtsx)
```

## Prérequis

- SQL Server (testé avec SQL Server 2025 Developer) et SSMS
- Visual Studio avec l'extension SQL Server Integration Services Projects
- Python 3, optionnel, pour régénérer les CSV

## Exécution

1. Optionnel : `python gen_translog.py data` régénère les CSV (résultat identique grâce à la graine fixe).
2. Placer le dépôt dans `C:\TransLog` (les chemins du script 01 en dépendent).
3. Dans SSMS, exécuter dans l'ordre : `01`, `02`, `02b`, `03`, `04`, puis `05`, `06` et `07`.
   Les scripts `01` et `02` recréent les tables : à n'utiliser qu'à l'initialisation.
4. Ouvrir `ssis/TransLog_ETL/TransLog_ETL.slnx` dans Visual Studio, ouvrir `P2_Charge_Staging.dtsx`, puis exécuter (F5).

Connexion utilisée : `localhost`, authentification Windows, base `translog_dw`.

## Résultats attendus

| Couche | Contenu |
|---|---|
| Staging | 8 entrepôts, 6 transporteurs, 60 clients, 3003 expéditions |
| DWH | 2995 lignes dans `fact_expedition` |
| Rejets | 8 lignes dans `etl.rejet` |

Les 8 lignes rejetées :

| Motif | Lignes |
|---|---|
| doublon | 3 |
| date inconnue (vide ou hors 2026) | 2 |
| statut inconnu | 1 |
| client inconnu | 1 |
| entrepôt inconnu | 1 |

Relancer le package donne le même résultat : le staging et la table de faits sont vidés avant chaque chargement, et les dimensions utilisent un `MERGE`.

## Choix de conception

- **Staging en NVARCHAR** : on charge tel quel, les erreurs de type ne bloquent jamais le chargement. Les conversions se font à la lecture, avec `TRY_CAST`.
- **Dimensions par `MERGE`** : insertion des nouveautés, mise à jour des valeurs modifiées, aucune suppression.
- **Statut en liste fixe** : c'est un référentiel. Une valeur inconnue n'entre pas dans la dimension, elle est rejetée.
- **Table de faits** : un Data Flow avec un `Conditional Split` pour les doublons et 5 `Lookup` qui récupèrent les clés de substitution. Les lignes sans correspondance sortent par la sortie *No Match*.
- **Rejets journalisés en T-SQL** après le Data Flow, avec le motif de chaque ligne.

## P3 : dimension client historisée (SCD type 2)

Script : `05_scd2_client.sql`. La ville et l'adresse sont historisées.

- Table `dwh.dim_client_scd2` : une ligne par version, avec `date_debut`, `date_fin` et `est_courant`. La version courante a `date_fin = 9999-12-31`.
- Procédure `etl.usp_load_dim_client_scd2 @date_effet`, en deux temps dans une transaction :
  1. fermeture des versions courantes dont la ville ou l'adresse a changé (`date_fin` = veille de `@date_effet`) ;
  2. création d'une version courante pour tout client qui n'en a pas (nouveau client ou version fermée).
- Rejouable : une relance sans changement dans le staging n'écrit rien (61 lignes avant et après).
- Les périodes sont fermées aux deux bornes (`date_fin` = veille du changement) : une date tombe dans une seule version, la recherche à une date donnée utilise donc `BETWEEN date_debut AND date_fin`.

## Chargement incrémental de la table de faits (watermark)

Script : `06_incremental_expeditions.sql`, test : `06b_test_incremental.sql`.

- Table de contrôle `etl.watermark` : plus grand `expedition_id` déjà chargé, initialisé à partir de la table de faits.
- Procédure `etl.usp_load_fact_expedition_incr` : ne charge que les expéditions au-dessus du repère, résout les clés de substitution par jointure sur les dimensions, puis avance le repère dans la même transaction que l'insertion.
- Rejouable : un second passage ne charge aucune ligne.
- Choix du repère : la source CSV n'a pas de date de modification, le watermark porte donc sur l'identifiant croissant.

## Déploiement et planification

1. Dans Visual Studio, `Build > Rebuild` produit `bin/Development/TransLog_ETL.ispac`.
2. Dans SSMS, créer le catalogue SSISDB (Integration Services Catalogs) et un dossier `TransLog`.
3. Clic droit sur `Projects > Deploy Project`, choisir le fichier `.ispac`, serveur `localhost`, chemin `/SSISDB/TransLog/TransLog_ETL`.
4. Exécuter `08_agent_job.sql` pour créer le job `TransLog - Charge faits incremental` (étape de type SSIS Catalog, planification quotidienne à 02h00).
5. Contrôle : `catalog.executions` (status 7 = succès, 4 = échec) et `etl.log_execution`.

Point d'attention : le job tourne sous le compte du service SQL Server Agent. Un package dont le `LocaleID` vaut 3072 (culture personnalisée générique de Windows) échoue sous ce compte avec l'erreur `Culture is not supported`, alors qu'il passe depuis SSMS. Le `LocaleID` de P3_Incremental est donc fixé à 1036 (français).

## P4 : ingestion depuis une API REST de suivi

Flux : API simulée (FastAPI) -> `api/ingest_tracking.py` -> CSV -> `stg.tracking_events` -> `dwh.fact_suivi_evenement`.

- Grain : un événement de suivi d'une expédition.
- Authentification par clé (`X-API-Key`), jamais committée.
- Pagination par curseur (`after_id`), qui sert aussi de watermark.
- Reprise automatique sur 503 et 429 avec backoff ; arrêt immédiat sur clé refusée.
- Écriture atomique du CSV (fichier temporaire puis renommage).
- Staging entièrement en `NVARCHAR` : le typage et les contrôles se font dans la procédure, une ligne invalide part en rejet sans bloquer le lot.
- Codes de sortie : 0 OK, 2 API indisponible, 3 authentification refusée, 4 réponse invalide, 5 configuration manquante.

Résultats du premier chargement :

- 4727 événements reçus en 10 pages (limit 500), 2 erreurs 503 reprises automatiquement.
- 4720 chargés, 7 rejetés (expédition inconnue), tracés dans `etl.rejet` : 4720 + 7 = 4727.
- 2e exécution : 0 ligne, watermark inchangé (idempotence).

Lancer :

```powershell
pip install -r api\requirements.txt
python -m pytest -q
$env:TRANSLOG_API_KEY="cle-de-demo"
python -m uvicorn api.mock_api:app --port 8000        # fenêtre 1
python api\ingest_tracking.py --after-id <watermark>  # fenêtre 2
```

Puis exécuter `09b_run_tracking_manual.sql` dans SSMS.

## Limites connues et suite

- Aucun contrôle de plausibilité sur les mesures : un poids négatif (expédition 26), un poids très élevé (41) et un volume vide (141) sont chargés dans la table de faits.
- Le package SSIS recharge toujours la table de faits en entier ; l'incrémental existe pour l'instant en T-SQL.
- Watermark sur l'identifiant : une expédition déjà chargée puis modifiée dans la source n'est pas reprise.
- La table de faits pointe encore vers `dim_client` (type 1) et non vers la version SCD2 valide à la date de l'expédition.
- Le watermark de P4 avance aussi sur les événements rejetés : ils ne sont plus redemandés à l'API (perte tracée dans `etl.rejet`, retraitement à prévoir).
- L'ingestion P4 est lancée à la main ; son package SSIS reste à construire.
- Pas encore de supervision centralisée (fraîcheur, santé des flux, alertes).

Prévu : liaison des faits à la version SCD2, package SSIS pour l'ingestion API, framework de contrôles qualité, supervision des flux.

## Auteur

Omar (github.com/Chekroun2004)
