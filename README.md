# noUSD

A stablecoin backed by one shared pool of stable/stable liquidity on Uniswap v4, held by
`NoUSDPositionManager`.
Mint with an allowed stable, burn for a pro-rata share of every position, earn pool fees through an
on-chain accumulator.

Project for the Uniswap Hook Incubator (UHI11). Specified, implementation in progress.

* [`docs/spec.md`](docs/spec.md) — **specification v1.1** (source of truth for the contracts)
* [`docs/vision.md`](docs/vision.md) — current model, decision log, open questions
* [`docs/nousd-model.ru.html`](docs/nousd-model.ru.html) — the same with diagrams (Russian; open in a browser)
* [`docs/simulation/`](docs/simulation/) — Monte-Carlo of fee-split schemes
