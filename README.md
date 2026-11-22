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
ssis/TransLog_ETL/       projet SSIS (package P2_Charge_Staging.dtsx)
```

## Prérequis

- SQL Server (testé avec SQL Server 2025 Developer) et SSMS
- Visual Studio avec l'extension SQL Server Integration Services Projects
- Python 3, optionnel, pour régénérer les CSV

## Exécution

1. Optionnel : `python gen_translog.py data` régénère les CSV (résultat identique grâce à la graine fixe).
2. Placer le dépôt dans `C:\TransLog` (les chemins du script 01 en dépendent).
3. Dans SSMS, exécuter dans l'ordre : `01`, `02`, `02b`, `03`, `04`, puis `05` et `06`.
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

## Limites connues et suite

- Aucun contrôle de plausibilité sur les mesures : un poids négatif (expédition 26), un poids très élevé (41) et un volume vide (141) sont chargés dans la table de faits.
- Le package SSIS recharge toujours la table de faits en entier ; l'incrémental existe pour l'instant en T-SQL.
- Watermark sur l'identifiant : une expédition déjà chargée puis modifiée dans la source n'est pas reprise.
- La table de faits pointe encore vers `dim_client` (type 1) et non vers la version SCD2 valide à la date de l'expédition.
- Pas encore de déploiement dans SSISDB, de planification SQL Server Agent ni de supervision.

Prévu : liaison des faits à la version SCD2, ingestion depuis une API REST simulée, framework de contrôles qualité, supervision des flux.

## Auteur

Omar (github.com/Chekroun2004)
