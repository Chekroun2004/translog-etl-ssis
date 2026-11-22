"""Generateur du jeu de donnees SYNTHETIQUE de TransLog Maroc (societe fictive).
Aucune donnee reelle. Reproductible grace a la graine fixe.
Usage: python gen_translog.py <dossier_sortie>
"""
import csv
import random
import sys
from datetime import date, timedelta
from pathlib import Path

random.seed(42)
out = Path(sys.argv[1] if len(sys.argv) > 1 else "data")
out.mkdir(parents=True, exist_ok=True)

VILLES = ["Casablanca", "Rabat", "Tanger", "Marrakech", "Fes", "Agadir", "Oujda", "Meknes", "Kenitra", "Tetouan"]
STATUTS = ["Livre", "En transit", "En preparation", "Retourne", "Annule"]
POIDS_STATUTS = [0.70, 0.12, 0.08, 0.06, 0.04]


def write(name, header, rows):
    # UTF-8 sans BOM, fins de ligne LF
    with open(out / name, "w", encoding="utf-8", newline="\n") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)


# Entrepots
entrepots = [(i + 1, f"ENT{i + 1:02d}", f"Entrepot {v}", v) for i, v in enumerate(VILLES[:8])]
write("entrepots.csv", ["id_entrepot", "code", "nom", "ville"], entrepots)

# Transporteurs
transporteurs = [(i + 1, f"Transporteur {n}", random.choice(["Interne", "Sous-traitant"]))
                 for i, n in enumerate(["Atlas", "Rif", "Sahara", "Chaouia", "Souss", "Doukkala"])]
write("transporteurs.csv", ["id_transporteur", "nom", "type"], transporteurs)

# Clients
clients = []
for i in range(1, 61):
    v = random.choice(VILLES)
    clients.append((i, f"Client {i:03d}", v, f"{random.randint(1, 120)} rue {random.randint(1, 40)}, {v}"))
write("clients.csv", ["id_client", "nom", "ville", "adresse"], clients)

# Expeditions
debut = date(2026, 1, 1)
nb = 3000
exp = []
for i in range(1, nb + 1):
    d = debut + timedelta(days=random.randint(0, 303))
    statut = random.choices(STATUTS, POIDS_STATUTS)[0]
    delai_prevu = random.randint(1, 4)
    retard = max(0, int(random.gauss(0.4, 1.2))) if statut == "Livre" else 0
    exp.append([
        i,
        random.randint(1, 60),
        random.randint(1, 8),
        random.randint(1, 6),
        d.isoformat(),
        round(random.uniform(5, 900), 1),
        round(random.uniform(0.05, 6.0), 2),
        statut,
        delai_prevu,
        delai_prevu + retard if statut == "Livre" else "",
    ])

# Anomalies volontaires (pour le projet P5 qualite): environ 1,5 %
exp[10][4] = ""                       # date manquante
exp[25][5] = -12.0                    # poids negatif
exp[40][5] = 4500000.0                # outlier de poids
exp[55][7] = "Livree??"               # statut hors liste
exp[70][1] = 9999                     # client inexistant
exp[85][2] = 99                       # entrepot inexistant
exp[100][4] = "2031-05-01"            # date dans le futur
for k in (120, 121, 122):             # trois lignes dupliquees
    exp.append(list(exp[k]))
exp[140][6] = ""                      # volume manquant

write("expeditions.csv",
      ["id_expedition", "id_client", "id_entrepot", "id_transporteur", "date_expedition",
       "poids_kg", "volume_m3", "statut", "delai_prevu_jours", "delai_reel_jours"], exp)
print("OK", len(entrepots), len(transporteurs), len(clients), len(exp))
