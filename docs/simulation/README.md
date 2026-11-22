# Fee-split simulation

`sim2.py` compares four ways to split pool fees between noUSD holders (A, B, C, C2 — see the
docstring) against three attackers (flash, snapshot, idle). Pure Python 3, no dependencies.

```bash
python3 sim2.py            # writes sim2.json
python3 sim2.py out.json   # or to a path of your choice
```

Seed 20261120; output is deterministic and matches the committed `sim2.json`.
Limitations: pool always in range, no depeg, no noUSD transfers, gas ignored, one fixed strategy per attacker.
