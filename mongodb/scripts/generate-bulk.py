#!/usr/bin/env python3
"""Generate bulk documents for load testing.

The curated 24 in data/movies.json carry the correctness assertions. These are volume:
same shape, ids from 1001 so they never collide, vectors clustered on the same five
themes with noise so nearest-neighbour results stay sane at scale.

  ./scripts/generate-bulk.py 20000 > data/bulk-movies.json
"""
import json, random, sys

random.seed(20260924)                      # deterministic: same corpus every run

THEMES = [
    ("underdog",  [0.90, 0.15, 0.02, 0.02, 0.03],
     ["fighter", "boxer", "wrestler", "runner", "climber", "rookie", "champion"],
     ["trains against the odds", "chases one last title", "returns to the ring"]),
    ("americana", [0.18, 0.90, 0.02, 0.02, 0.04],
     ["pitcher", "coach", "scout", "catcher", "manager", "slugger"],
     ["rebuilds a losing team", "returns to the diamond", "chases a pennant"]),
    ("creature",  [0.03, 0.05, 0.90, 0.20, 0.08],
     ["shark", "creature", "swarm", "predator", "parasite", "beast"],
     ["stalks an isolated crew", "terrorises a coastal town", "infiltrates a station"]),
    ("space",     [0.05, 0.05, 0.10, 0.92, 0.05],
     ["astronaut", "pilot", "engineer", "colonist", "navigator"],
     ["is stranded beyond rescue", "races a failing life-support system", "maps a dead world"]),
    ("noir",      [0.03, 0.04, 0.05, 0.03, 0.92],
     ["detective", "fixer", "informant", "lieutenant", "investigator"],
     ["uncovers civic corruption", "chases a missing heiress", "works a cold case"]),
]
ADJ    = ["Last", "Silent", "Broken", "Crimson", "Hollow", "Distant", "Iron", "Quiet",
          "Long", "Bitter", "Pale", "Restless", "Burning", "Frozen", "Stolen"]
NOUN   = ["Harbour", "Circuit", "Season", "Signal", "Descent", "Verdict", "Horizon",
          "Gambit", "Contract", "Reckoning", "Passage", "Assignment", "Tide"]
GENRE  = {"underdog": "drama", "americana": "drama", "creature": "thriller",
          "space": "sci-fi", "noir": "noir"}

def jitter(base):
    v = [max(0.0, min(1.0, c + random.uniform(-0.09, 0.09))) for c in base]
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [round(x / n, 4) for x in v]            # unit length: cosine behaves

def main(n):
    docs = []
    for i in range(n):
        theme, base, actors, arcs = THEMES[i % len(THEMES)]
        docs.append({
            "_id": 1001 + i,
            "title": f"The {random.choice(ADJ)} {random.choice(NOUN)} {i + 1}",
            "year": random.randint(1950, 2024),
            "genre": GENRE[theme],
            "theme": theme,
            "plot": f"A {random.choice(actors)} {random.choice(arcs)}.",
            "plot_embedding": jitter(base),
        })
    json.dump(docs, sys.stdout)

if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 20000)
