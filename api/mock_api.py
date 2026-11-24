"""API de suivi des expeditions de TransLog Maroc (societe FICTIVE).

Simule une vraie API REST de suivi :
- authentification par cle d'API (en-tete X-API-Key)
- pagination par curseur (after_id) : stable quand de nouveaux evenements arrivent
- limite de debit (429 + Retry-After)
- pannes simulees (503) pour tester la reprise du client

Les evenements sont derives de data/expeditions.csv, de facon deterministe.
La date "courante" simulee (SIM_NOW) fait apparaitre de nouveaux evenements au fil du temps.

Lancement (PowerShell, depuis C:\\TransLog) :
    $env:TRANSLOG_API_KEY = "cle-de-demo"
    uvicorn api.mock_api:app --port 8000
"""
import csv
import os
import time
from datetime import datetime, timedelta
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Query, Response

DATA = Path(__file__).resolve().parent.parent / "data" / "expeditions.csv"

# Chaine d'evenements selon le statut final de l'expedition.
CHAINES = {
    "En preparation": ["En preparation"],
    "En transit": ["En preparation", "En transit"],
    "Livre": ["En preparation", "En transit", "Livre"],
    "Retourne": ["En preparation", "En transit", "Retourne"],
    "Annule": ["En preparation", "Annule"],
}

app = FastAPI(title="TransLog Maroc - API de suivi (fictive)")

_appels = {}      # cle d'API -> horodatages des appels recents (limite de debit)
_compteur = {"n": 0}


def reset_state():
    """Remet a zero les compteurs (utile pour les tests)."""
    _appels.clear()
    _compteur["n"] = 0


@lru_cache(maxsize=4)
def generer_evenements(chemin: str):
    """Construit la liste des evenements, tries par date, avec un id croissant."""
    bruts = []
    with open(chemin, newline="", encoding="utf-8") as f:
        for ligne in csv.DictReader(f):
            try:
                id_exp = int(ligne["id_expedition"])
                debut = datetime.strptime(ligne["date_expedition"], "%Y-%m-%d")
            except (ValueError, KeyError):
                continue  # ligne source inexploitable : l'API ne la publie pas
            statut = ligne["statut"].strip()
            chaine = CHAINES.get(statut, ["En preparation", statut])
            delai = ligne.get("delai_reel_jours") or ligne.get("delai_prevu_jours") or "2"
            try:
                delai = max(int(delai), 1)
            except ValueError:
                delai = 2
            prep = debut + timedelta(hours=8)
            if statut == "Annule":
                moments = [prep, debut + timedelta(days=1, hours=10)]
            elif len(chaine) == 1:
                moments = [prep]
            elif len(chaine) == 2:
                moments = [prep, debut + timedelta(hours=12)]
            else:
                moments = [prep, debut + timedelta(hours=12),
                           debut + timedelta(days=delai, hours=16)]
            for st, ts in zip(chaine, moments):
                bruts.append((ts, id_exp, st))
    bruts.sort(key=lambda e: (e[0], e[1]))
    return [
        {
            "id_evenement": i,
            "id_expedition": id_exp,
            "statut": st,
            "horodatage": ts.strftime("%Y-%m-%dT%H:%M:%S"),
        }
        for i, (ts, id_exp, st) in enumerate(bruts, start=1)
    ]


def _maintenant():
    return os.environ.get("SIM_NOW", "2026-06-30T23:59:59")


@app.get("/api/v1/tracking-events")
def tracking_events(
    response: Response,
    after_id: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=1000),
    x_api_key: str | None = Header(None),
):
    attendue = os.environ.get("TRANSLOG_API_KEY")
    if not attendue:
        raise HTTPException(500, "TRANSLOG_API_KEY non configuree cote serveur")
    if x_api_key != attendue:
        raise HTTPException(401, "Cle d'API invalide")

    # Limite de debit : N appels par minute et par cle.
    limite = int(os.environ.get("RATE_LIMIT_PER_MIN", "60"))
    maintenant = time.monotonic()
    recents = [t for t in _appels.get(x_api_key, []) if maintenant - t < 60]
    if len(recents) >= limite:
        attente = max(1, int(60 - (maintenant - recents[0])) + 1)
        raise HTTPException(429, "Trop de requetes", headers={"Retry-After": str(attente)})
    recents.append(maintenant)
    _appels[x_api_key] = recents

    # Panne simulee : une requete sur N renvoie 503.
    _compteur["n"] += 1
    n = int(os.environ.get("FAIL_EVERY", "0"))
    if n and _compteur["n"] % n == 0:
        raise HTTPException(503, "Service temporairement indisponible")

    limite_temps = _maintenant()
    visibles = [
        e for e in generer_evenements(str(DATA))
        if e["id_evenement"] > after_id and e["horodatage"] <= limite_temps
    ]
    page = visibles[:limit]
    return {
        "data": page,
        "next_after_id": page[-1]["id_evenement"] if page else after_id,
        "has_more": len(visibles) > limit,
    }
