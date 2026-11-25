# Claude Design brief — noUSD web app

Paste everything below the line into https://claude.ai/design and attach the files listed in
"Attachments". The brief is self-contained; the attachments carry the visual system.

---

## Who you are and what to make

You are the product designer for **noUSD**, a new product in the **Envelop** family. Its sibling,
**unisafe** (https://unisafe.envelop.is), already has a finished visual system — dark, cool near-black,
Envelop mint accent, Space Grotesk / Hanken Grotesk / JetBrains Mono. **noUSD must look like it was
made by the same team on the same day**: reuse unisafe's tokens, type, radii, components and tone
exactly (attached: the unisafe design handoff README, its interactive HTML reference and screenshots
of the live site). Do not invent a new palette. Where noUSD needs something unisafe does not have
(a basket composition, a redeem preview, a timelock queue), build it from the same parts.

Make a **high-fidelity, clickable prototype** of the noUSD web app (desktop 1440 wide, content max
1160; plus phone 390 for the four main flows) and a short **handoff README** in the same format as
the attached unisafe one: tokens, screens, states, interactions, what data feeds each number.

## The product in one paragraph

noUSD is an ERC-20 stablecoin backed by one shared pool of stable/stable liquidity on **Uniswap v4**.
Anyone deposits one allowed stablecoin (USDC, USDT, DAI, USDe…); in the same transaction it is put to
work as liquidity in an existing Uniswap v4 stable pool, and the user receives noUSD for the value
added. **1 noUSD = 1 unit of the stable basket** (all allowed stables count 1:1 with each other), not
a promise of $1. Pool trading fees are earned by holders over time and taken with **Claim**, paid in
stables, without selling noUSD. **Redeem** (burn) returns a pro-rata slice of every position and of
the idle balances — in kind, in several tokens at once — to any address the user chooses. Nobody can
move the funds: there is no operator, the contracts are immutable, parameters change only through a
2-of-3 multisig with a 48-hour delay for anything that loosens rules, and redeem and claim can never
be paused.

## Mental model the UI must teach

- **Mint** = "deposit one stable, get noUSD for what it adds". A small part may be swapped to pair it;
  any leftover comes back. The swap costs about 0.01–0.03 %.
- **Hold** = noUSD sits in the wallet and earns. Earnings ("accrued") grow when the protocol syncs
  fees (hourly on L2, daily on Ethereum). Wallets earn automatically; **smart contracts do not earn
  unless they opt in** — show this clearly for contract wallets.
- **Claim** = take what you earned, in stables, keep your noUSD.
- **Redeem** = burn noUSD, get your share of the basket: e.g. 1,000 noUSD → 312.4 USDe + 188.1 USDC +
  251.0 DAI + 249.2 USDT. Earned-but-unclaimed fees are paid in the same redeem.
- **Per chain.** Each network has its own independent noUSD (Ethereum first, Arbitrum / Unichain /
  Base later). noUSD on one chain is **not** the same token as on another and there is no bridge. The
  network control is a real selector here (unlike unisafe), and the app must say plainly which chain's
  noUSD the user is looking at.

## Visual system (from unisafe — reuse exactly)

| Token | Value | Use |
|---|---|---|
| bg | #0A0C10 | app background |
| s1 / s2 / s3 | #101319 / #161A22 / #1D222C | cards / inputs, chips / tracks, hover |
| line / line2 | rgba(255,255,255,.07) / .11 | hairlines / stronger borders |
| tx / tx2 / tx3 | #EAEEF4 / #9AA4B2 / #626C7A | text primary / secondary / labels |
| accent | #34E3AC (Envelop mint) | CTAs, earning, in-range, positive |
| accent-soft / accent-line | rgba(52,227,172,.12) / .30 | tinted fills / accent borders |
| warn | #FFC76B | off-peg, swap notices, pending, timelock |
| danger | #FF7A7A | refused payout, destructive |

Primary button: mint background, text #03110C, weight 700, radius 12, shadow `0 6px 20px -8px accent-line`.
Type: **Space Grotesk** 600/700 for headings and big numbers (−0.02em), **Hanken Grotesk** for UI,
**JetBrains Mono** with tabular numerals for every amount, address, ID, tick and percentage. Never below
11 px. Radii: cards 16–20, modals 22, inputs 11–14, chips 8–13, pills 20. Sticky blurred header 64 px.
Status dots: mint with glow + slow pulse = live/in range; amber = attention; hollow = idle. Token chips:
real logos when available, else colored circles (USDC #2775CA, USDT #26A17B, DAI #F5AC37,
USDe #111 with white "e", USDS #F4B731, RLUSD #0B1F3A). Dark only, like unisafe.

**noUSD identity inside the family:** wordmark "noUSD" (Space Grotesk 700, "no" in tx, "USD" in
accent, or the reverse — propose two options), a mark built from unisafe's concentric-rings motif but
split into several arcs (the basket of positions). Footer "noUSD — powered by Envelop".

## Screens

### 1. Landing (`/`)
- Hero: "One stablecoin, backed by Uniswap v4 stable liquidity. Earn the fees." Sub: "Deposit any
  allowed stable. Redeem for the basket any time, to any address." CTAs **Open the app**, **How it works**.
- Live strip (mono numbers): noUSD supply, backing at par, holder APR (7d), pools, last sync time.
- How it works — 4 steps in unisafe's flow-infographic style (icon badges + connectors):
  Deposit a stable → Works as Uniswap v4 liquidity (same tx) → Fees accrue to holders → Claim or Redeem
  (basket to any address). A return arrow from Claim back to "Hold".
- Basket: stacked bar + list of the backing by token and by pool (see example data).
- "Why it is safe" cards: no operator can move funds · immutable contracts, caps in code · loosening
  waits 48 h, visible on-chain · redeem and claim cannot be paused · the price guard only opens
  minting, never blocks exits.
- FAQ (accordion like unisafe): is 1 noUSD = $1? (no: 1 unit of the basket; if one stable depegs,
  noUSD honestly reflects it) · where do earnings come from · why do I get several tokens on redeem ·
  can my smart wallet earn · what does "per chain" mean · what are the fees.

### 2. App — Mint (`/app/mint`)
Card like unisafe's Deposit: token selector (only mintable tokens of the current chain), amount + MAX,
balance. **Preview** (updates live): pool it goes to (pair chips + fee), "≈ X swapped in POOL" (or
"paired with idle — no swap" in mint), "You receive ≈ N noUSD", "Refund ≈ r TOKEN", price-guard status
(mint open / closed for this token), supply cap usage bar. Settings popover: slippage (min received),
deadline. Approve → Mint (support one-click permit where the token allows).
States: mint closed for a token (the price guard has no fresh price — e.g. USDT on Unichain: "Minting
with USDT is closed on this network. Redeem and claim work."); off-peg ("USDT is 0.6 % off par; minting
with it is paused until it returns"); supply cap reached; mint paused by governance; slippage exceeded;
success with tx link and "noUSD added to wallet".

### 3. App — Redeem (`/app/redeem`)
Amount of noUSD + MAX. **Destination** picker exactly like unisafe's Withdraw (My wallet / Custom
address, resolved-recipient strip). **Preview of the basket you get**: one row per token with amount and
value at par, plus "includes your unclaimed earnings: E". Min received setting.
Delayed mode (a parameter, off at launch, show it anyway): if a redeem delay is set, the CTA becomes
"Request redeem · ready in 24 h", and a **Pending redeems** list shows each request (amount, ready at /
countdown, recipient, Cancel). Copy: "Your noUSD is held until then and stops earning; the payout is
computed when it executes."
State: **a token refused the recipient** — e.g. "USDT refused to send to 0xB7…93B2 (address frozen by
USDT). Redeem to another address." with a one-click switch to Custom. Never show raw errors.

### 4. App — Earnings / Claim (`/app/earn`)
Big "Unclaimed earnings" number, "earning since", APR 7d/30d, next sync ETA. **Claim** with the same
basket preview and destination picker. For a smart-contract wallet: amber card "This address is a
contract and does not earn yet" + **Turn on earning** (calls opt-in) with a one-line explanation.

### 5. App — Portfolio (`/app`)
Summary: noUSD balance, value at par, unclaimed earnings, earning on/off, pending redeems. Quick
actions Mint / Redeem / Claim. Activity list (mint, redeem, claim, transfers) with mono amounts.

### 6. Transparency (`/reserves`)
Everything that backs noUSD, read on-chain:
- Totals: supply, unclaimed earnings, treasury accrual, carry, backing value at par, backing / supply.
- **Pools** table: pair chips, fee, status (Active / Withdraw only), price vs par (in ticks/bp, warn
  if off-peg), in range dot, our liquidity share vs cap (bar with cap marker), position value, fee APR,
  range min–max.
- Idle balances by token (held in the Uniswap PoolManager).
- Price guard status per pool (vouched / no fresh price).
- Keeper: last sync, last compound per pool.

### 7. Governance (`/governance`)
Parameters with current value and **hard cap from code** side by side (redeem delay ≤ 7 d, mint fee
≤ 0.5 %, protocol fee ≤ 10 %, depeg threshold 0.01–2 %, pool share cap ≤ 50 %, supply cap). Owner
(Safe 2-of-3). **Timelock queue**: pending changes with old → new, "executes after" countdown,
status (queued / executable / cancelled / executed). Copy explaining: "Changes that loosen rules wait
48 h so holders can leave first; tightening applies at once."

### Global
Header: noUSD mark + wordmark, version pill, nav (App, Reserves, Governance, Docs), **network
selector** (Ethereum, Arbitrum, Unichain, Base — with "soon" for undeployed ones), wallet button.
Toasts like unisafe. Advanced toggle (unisafe pattern) reveals full addresses, pool IDs, ticks.
Empty states, loading skeletons (no full-page fades), wrong-network state, disconnected state.

## Example data (Ethereum, for the mock — format examples only)

- Supply 84,210.55 noUSD · backing 84,236.10 at par · unclaimed 241.18 · treasury 0 · holder APR 7d 6.2 %
- Pools: **USDe / USDC** fee 0.0025 % · Active · TVL $861k · fee APR 10.8 % · our share 9.8 % (cap 30 %)
  · position $48,920 · in range · **DAI / USDT** fee 0.0068 % · Active · TVL $596k · APR 1.5 % · share
  5.9 % · position $35,004 · in range · **USDS / RLUSD** fee 0.0005 % · Withdraw only · position $0
- Idle: 212.40 USDC · 99.71 USDe
- Mint 10,000 USDC → ≈ 9,994.10 noUSD, refund ≈ 4.7 USDe, swap ≈ 4,500 USDC in USDe/USDC
- Redeem 1,000 noUSD → 290.5 USDe + 290.6 USDC + 208.8 DAI + 208.7 USDT (+ 2.86 earnings included)
- Params: redeem delay 0 · mint fee 0 · protocol fee 0 · depeg 0.5 % · share cap 30 % · supply cap 100,000
- Timelock: "Raise supply cap 100,000 → 250,000 · executes in 31 h"
- Addresses: use realistic truncated mono forms (0x4c9E…68B3).

## Rules

- Same system as unisafe; dark only; mono tabular numbers everywhere money appears.
- Never show raw contract errors. Map them: Slippage → "Price moved; you would get less than your
  minimum." · Expired → "Took too long; try again." · PayoutFailed → token refused recipient (above) ·
  OracleNoOpinion → mint closed for this token · PegCheckFailed → off par · SupplyCapExceeded ·
  MintPaused · UseRequestBurn → delayed mode.
- Say "redeem for the basket", not "redeem for $1". Say "earnings", not "rewards" or "yield farming".
- No leverage, no "APY guaranteed" language, no fake urgency.
- Accessibility: contrast AA on all text, focus states, states carried by shape/label not color only.

## Attachments (upload with this brief)

1. `stablelp-ui/tasks/design_handoff_unisafe_redesign/README.md` — the unisafe visual spec (tokens,
   components, interaction rules). Treat as the source of truth for look and feel.
2. `stablelp-ui/tasks/design_handoff_unisafe_redesign/Unisafe Dashboard.dc.html` — interactive unisafe
   reference (ignore its `<x-dc>` runtime; read markup and measurements).
3. `docs/design/refs/unisafe-landing.png`, `unisafe-app.png`, `unisafe-strategies.png` — the live site.
4. Product background (optional): https://github.com/maxsiz/uhi11-nousd/blob/main/docs/spec.md and the
   decisions page https://claude.ai/artifact/Cq1MBPS1MTGwJF5tNoEBUt.

## Out of scope

Bridging, a $1 peg module, operator or admin consoles beyond the read-only Governance page, light theme.
