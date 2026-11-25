# noUSD — demo video script (≤ 5 min)

Recorded by a person: no AI voice (hackathon rule). Target 4:30, which leaves room to breathe. Screen at
1440 px, browser zoom 110 %. Times are cumulative. **Say** is the voice-over; **Show** is the screen.

Judging weights, to keep the emphasis right: idea 30 %, execution 25 %, impact 20 %, functionality 15 %,
pitch 10 %.

---

## 0:00 – 0:30 · The problem (idea)

**Show:** the landing hero at nousd.envelop.is.

**Say:** "Stable/stable pools on Uniswap earn real fees, but the stablecoins in them earn nothing for the
people who hold them. And if you're an LP, you hold an NFT position instead of money you can spend. noUSD
merges the two: the stablecoin **is** the LP share. You deposit any allowed stable, get noUSD, and the pool
fees go to whoever holds it."

## 0:30 – 1:40 · Why this is a v4 project (execution, the core)

**Show:** scroll to "Every mint and redeem is one unlock()". Let the mint walkthrough play, pausing on
steps 1, 3 and 5 by clicking them. Point at the delta ledger.

**Say:**
- "noUSD has no hook, and that's deliberate. It lives inside v4's PoolManager and uses what v4 added:
  flash accounting, the singleton and ERC-6909."
- Step 1: "Your deposit goes straight into the PoolManager — not to our contract. The manager gets a
  credit."
- Step 2: "We pair it with idle balances that already sit in the PoolManager as ERC-6909 claims."
- Step 3: "Only the missing part is swapped — as a delta, in any registered pool, never past the depeg
  limit. Thanks to the singleton, the swap and the add can be in different pools."
- Step 5: "Then every delta is closed. Look at the counter: in the whole mint, only **two** token
  transfers touch your wallet — the deposit and the change."
- Step 6: "Finally the price guard checks the pegs against Chainlink, and the share cap is enforced. If
  anything is off, the whole unlock reverts."

**Show:** switch to Redeem and let it play.

**Say:** "Redeem is one unlock too: a slice of every position and of idle, paid with `take` straight to
any address you choose."

## 1:40 – 3:10 · The app (functionality)

**Show:** App → Mint. Type 10,000 USDC. Point at the preview: pool, pairing, swap cost, "You receive",
minimum received, price guard, supply cap. Mint → success screen.

**Say:** "The preview shows exactly what the unlock will do. Pairing with idle means there's often no swap
at all."

**Show:** Prototype states → Mint outcome "Off par". Point at the notice and the disabled CTA. Then
"Slippage".

**Say:** "If a stable depegs, minting with it closes. Exits never close."

**Show:** Redeem → pick "Custom address" → back to "My wallet". Prototype states → "USDT refuses my
wallet" → redeem → refused card → "Use a custom address".

**Say:** "Redeem pays in kind, to any address. If a token has frozen your address, nothing is lost — the
whole redeem reverts and you pick another address."

**Show:** Earnings → Claim. Prototype states → Wallet "Contract" → the opt-in card.

**Say:** "Earnings are claimed in stables while you keep your noUSD. Contracts such as pools and vaults
are opted out until they opt in, so they don't silently soak up the yield."

## 3:10 – 3:50 · Safety and governance (execution, impact)

**Show:** Reserves (pools table: share vs cap, price vs par), then Governance (parameters with hard caps,
timelock queue).

**Say:** "Everything that backs noUSD is on-chain and public. No operator can move funds. Every
maintenance call is permissionless. Contracts are immutable, every parameter has a hard cap in code,
loosening waits 48 hours, and redeem and claim can never be paused."

## 3:50 – 4:20 · It works (functionality)

**Show:** terminal: `forge test --summary` (138 passing), then the fork test line; the README gas table.

**Say:** "138 tests, including fuzzing, invariants and mainnet fork tests against the real USDe/USDC and
DAI/USDT pools and the deployed price guard. A mint — settle, swap, add, refund and checks — costs about
600k gas."

## 4:20 – 4:45 · Impact and close

**Show:** back to the landing hero.

**Say:** "noUSD makes existing v4 stable pools deeper instead of fragmenting liquidity. It turns LP fees
into a stablecoin yield anyone can hold, transfer or use as a payment token — it even supports gasless
EIP-3009 transfers. noUSD: one stablecoin, backed by Uniswap v4 stable liquidity. Thanks!"

---

### Recording checklist

- Demo mode is on in production: the Prototype states dock is bottom-left. Reset the states between
  takes.
- If the contracts are deployed before recording, replace the Prototype-states parts with real
  transactions on testnet and say so.
- Mention once that the hook exception was approved, if the judges might ask.
- Keep it under 5:00 — cut 3:10–3:50 first if it runs long.
