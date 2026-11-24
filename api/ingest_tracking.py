"""Ingestion des evenements de suivi depuis l'API REST vers un CSV (TransLog Maroc, fictif).

Principe : ce script ne touche pas a la base. Il appelle l'API, gere la pagination,
l'authentification et la reprise sur erreur, puis ecrit un CSV que SSIS charge en staging.
Le watermark (dernier id_evenement deja charge) est fourni par SSIS via --after-id.

Codes de sortie (lus par la tache Execute Process de SSIS) :
    0 succes (meme avec 0 ligne)   2 API indisponible apres reprises
    3 authentification refusee     4 reponse inattendue   5 configuration manquante
"""
import argparse
import csv
import json
import logging
import os
import sys
import tempfile
import time
from pathlib import Path

import requests

COLONNES = ["id_evenement", "id_expedition", "statut", "horodatage"]
RACINE = Path(__file__).resolve().parent.parent
ATTENTE_MAX = 60  # secondes : on ne dort jamais plus, meme si Retry-After est grand

log = logging.getLogger("ingest_tracking")


class IngestError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def lire_cle_api():
    """Variable d'environnement d'abord, sinon fichier api/.api_key (non versionne)."""
    cle = os.environ.get("TRANSLOG_API_KEY")
    if cle:
        return cle.strip()
    fichier = Path(__file__).resolve().parent / ".api_key"
    if fichier.exists():
        return fichier.read_text(encoding="utf-8").strip()
    raise IngestError("Cle d'API absente (TRANSLOG_API_KEY ou api/.api_key)", 5)


def get_avec_reprise(session, url, params, headers, max_reprises=5, base=1.0, dormir=time.sleep):
    """GET avec reprise : 429 et 5xx sont repris (backoff exponentiel, Retry-After respecte)."""
    for essai in range(max_reprises + 1):
        raison = None
        attente = min(base * 2 ** essai, ATTENTE_MAX)
        try:
            rep = session.get(url, params=params, headers=headers, timeout=30)
        except requests.RequestException as exc:
            raison = f"erreur reseau : {exc}"
        else:
            if rep.status_code == 200:
                return rep
            if rep.status_code in (401, 403):
                raise IngestError(f"Authentification refusee (HTTP {rep.status_code})", 3)
            if rep.status_code == 429 or rep.status_code >= 500:
                raison = f"HTTP {rep.status_code}"
                retry = rep.headers.get("Retry-After")
                if retry and retry.isdigit():
                    attente = min(int(retry), ATTENTE_MAX)
            else:
                raise IngestError(f"Reponse inattendue : HTTP {rep.status_code}", 4)
        if essai == max_reprises:
            raise IngestError(f"API indisponible apres {max_reprises} reprises ({raison})", 2)
        log.warning("%s, nouvel essai dans %ss (%d/%d)", raison, attente, essai + 1, max_reprises)
        dormir(attente)


def recuperer_tout(base_url, cle, apres_id, limite=500, session=None, dormir=time.sleep):
    """Parcourt toutes les pages (curseur after_id) et renvoie la liste des evenements."""
    session = session or requests.Session()
    url = f"{base_url.rstrip('/')}/api/v1/tracking-events"
    evenements, curseur, pages = [], apres_id, 0
    while True:
        rep = get_avec_reprise(session, url, {"after_id": curseur, "limit": limite},
                               {"X-API-Key": cle}, dormir=dormir)
        try:
            corps = rep.json()
            page = corps["data"]
            suivant = corps["next_after_id"]
            encore = corps["has_more"]
        except (ValueError, KeyError, TypeError) as exc:
            raise IngestError(f"Reponse JSON invalide : {exc}", 4)
        for e in page:
            if not all(c in e for c in COLONNES):
                raise IngestError(f"Evenement incomplet : {e}", 4)
        evenements.extend(page)
        pages += 1
        if encore and suivant <= curseur:
            raise IngestError("Curseur bloque (has_more sans progression)", 4)
        curseur = suivant
        if not encore:
            return evenements, pages


def ecrire_csv(evenements, chemin):
    """Ecriture atomique : fichier temporaire puis remplacement, jamais de CSV a moitie ecrit."""
    chemin = Path(chemin)
    chemin.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=chemin.parent, suffix=".tmp")
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(COLONNES)
        for e in evenements:
            w.writerow([e[c] for c in COLONNES])
    os.replace(tmp, chemin)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--after-id", type=int, required=True, help="watermark : dernier id deja charge")
    p.add_argument("--base-url", default="http://127.0.0.1:8000")
    p.add_argument("--limit", type=int, default=500)
    p.add_argument("--out", default=str(RACINE / "data" / "tracking_events.csv"))
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")
    try:
        cle = lire_cle_api()
        evenements, pages = recuperer_tout(args.base_url, cle, args.after_id, args.limit)
    except IngestError as exc:
        log.error("%s", exc)
        return exc.code
    ecrire_csv(evenements, args.out)
    dernier = evenements[-1]["id_evenement"] if evenements else args.after_id
    print(json.dumps({"lignes": len(evenements), "pages": pages,
                      "after_id": args.after_id, "dernier_id": dernier}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
