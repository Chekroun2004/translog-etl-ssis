"""Tests de l'API simulee et du client d'ingestion. Lancer : python -m pytest -q"""
import csv

import pytest
import requests
from fastapi.testclient import TestClient

from api import ingest_tracking as ing
from api import mock_api

CLE = "cle-de-test"


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("TRANSLOG_API_KEY", CLE)
    monkeypatch.setenv("SIM_NOW", "2026-12-31T23:59:59")
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "1000")
    monkeypatch.setenv("FAIL_EVERY", "0")
    mock_api.reset_state()


@pytest.fixture
def client():
    return TestClient(mock_api.app)


H = {"X-API-Key": CLE}
URL = "/api/v1/tracking-events"


# ---------- API ----------

def test_cle_absente_ou_fausse_refusee(client):
    assert client.get(URL).status_code == 401
    assert client.get(URL, headers={"X-API-Key": "mauvaise"}).status_code == 401


def test_pagination_sans_doublon_ni_trou(client):
    vus, curseur = [], 0
    while True:
        r = client.get(URL, params={"after_id": curseur, "limit": 700}, headers=H).json()
        vus += [e["id_evenement"] for e in r["data"]]
        curseur = r["next_after_id"]
        if not r["has_more"]:
            break
    assert vus == list(range(1, len(vus) + 1))
    assert len(vus) > 5000


def test_sim_now_limite_les_evenements(client, monkeypatch):
    tout = client.get(URL, params={"limit": 1000}, headers=H).json()["data"]
    monkeypatch.setenv("SIM_NOW", "2026-03-01T00:00:00")
    partiel = client.get(URL, params={"limit": 1000}, headers=H).json()["data"]
    assert partiel and all(e["horodatage"] <= "2026-03-01T00:00:00" for e in partiel)
    assert len(partiel) < len(tout) or len(tout) == 1000


def test_limite_de_debit_renvoie_429_avec_retry_after(client, monkeypatch):
    monkeypatch.setenv("RATE_LIMIT_PER_MIN", "2")
    assert client.get(URL, headers=H).status_code == 200
    assert client.get(URL, headers=H).status_code == 200
    r = client.get(URL, headers=H)
    assert r.status_code == 429 and int(r.headers["Retry-After"]) >= 1


def test_chaque_expedition_commence_par_en_preparation(client):
    r = client.get(URL, params={"limit": 1000}, headers=H).json()["data"]
    premiers = {}
    for e in r:
        premiers.setdefault(e["id_expedition"], e["statut"])
    assert set(premiers.values()) == {"En preparation"}


# ---------- Client d'ingestion (sans reseau : fausse session) ----------

class Rep:
    def __init__(self, code, corps=None, entetes=None):
        self.status_code, self._corps, self.headers = code, corps, entetes or {}

    def json(self):
        if self._corps is None:
            raise ValueError("pas de JSON")
        return self._corps


class FausseSession:
    def __init__(self, reponses):
        self.reponses, self.appels = list(reponses), []

    def get(self, url, params=None, headers=None, timeout=None):
        self.appels.append(dict(params))
        r = self.reponses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def evt(i):
    return {"id_evenement": i, "id_expedition": 1, "statut": "Livre",
            "horodatage": "2026-01-01T08:00:00"}


def page(ids, apres, encore):
    return Rep(200, {"data": [evt(i) for i in ids], "next_after_id": apres, "has_more": encore})


def test_reprise_apres_503_puis_429_respecte_retry_after():
    pauses = []
    s = FausseSession([Rep(503), Rep(429, entetes={"Retry-After": "7"}), page([1, 2], 2, False)])
    evts, pages = ing.recuperer_tout("http://x", CLE, 0, session=s, dormir=pauses.append)
    assert [e["id_evenement"] for e in evts] == [1, 2] and pages == 1
    assert pauses == [1.0, 7]  # backoff 1s, puis Retry-After


def test_reseau_coupe_est_repris():
    s = FausseSession([requests.ConnectionError("coupure"), page([1], 1, False)])
    evts, _ = ing.recuperer_tout("http://x", CLE, 0, session=s, dormir=lambda _: None)
    assert len(evts) == 1


def test_abandon_apres_trop_de_reprises_code_2():
    s = FausseSession([Rep(503)] * 10)
    with pytest.raises(ing.IngestError) as exc:
        ing.recuperer_tout("http://x", CLE, 0, session=s, dormir=lambda _: None)
    assert exc.value.code == 2


def test_authentification_refusee_pas_de_reprise_code_3():
    s = FausseSession([Rep(401), page([1], 1, False)])
    with pytest.raises(ing.IngestError) as exc:
        ing.recuperer_tout("http://x", CLE, 0, session=s, dormir=lambda _: None)
    assert exc.value.code == 3 and len(s.appels) == 1


def test_curseur_envoye_a_chaque_page():
    s = FausseSession([page([6, 7], 7, True), page([8], 8, False)])
    evts, pages = ing.recuperer_tout("http://x", CLE, 5, limite=2, session=s)
    assert [a["after_id"] for a in s.appels] == [5, 7] and pages == 2 and len(evts) == 3


def test_json_invalide_code_4():
    s = FausseSession([Rep(200, None)])
    with pytest.raises(ing.IngestError) as exc:
        ing.recuperer_tout("http://x", CLE, 0, session=s)
    assert exc.value.code == 4


def test_curseur_bloque_detecte():
    s = FausseSession([page([], 5, True)])
    with pytest.raises(ing.IngestError):
        ing.recuperer_tout("http://x", CLE, 5, session=s)


def test_csv_ecrit_avec_entete_meme_vide(tmp_path):
    sortie = tmp_path / "t.csv"
    ing.ecrire_csv([], sortie)
    assert sortie.read_text(encoding="utf-8") == ",".join(ing.COLONNES) + "\n"
    ing.ecrire_csv([evt(1)], sortie)
    lignes = list(csv.reader(sortie.open(encoding="utf-8")))
    assert lignes[0] == ing.COLONNES and lignes[1][0] == "1"
    assert not list(tmp_path.glob("*.tmp"))
