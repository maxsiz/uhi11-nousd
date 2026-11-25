# Unichain Sepolia (1301) test deployment

Unichain Sepolia has the v4 `PoolManager` and the unisafe price guard, but no stable/stable v4 pools.
`DeployTestnet.s.sol` therefore creates its own launch set, then runs the regular `Deploy.deploy`:

| What | Details |
|---|---|
| Test stables | `tUSDC` (6 dec), `tUSDT` (6 dec), `tDAI` (18 dec): plain ERC-20s with an open `faucet(to, amount)`, ≤ 1M tokens per call |
| Pools (hookless, tickSpacing 1) | tUSDC/tUSDT fee 10, tDAI/tUSDC fee 5, tDAI/tUSDT fee 100; initialized at par, ≈ 250k per side of outside liquidity within ±200 ticks |
| Routers | v4-core `PoolModifyLiquidityTest` and `PoolSwapTest`; anyone can swap a pool off par to show the depeg guard |
| noUSD | registry → manager → token, all three tokens mintable, all three pools Active, preset par ± 100 ticks, supply cap 1M, compound threshold 50 |
| Oracle | the deployed unisafe `ChainlinkPriceOracle` `0x36fD134928577f9fF317bF621CBa03Da26716411` |

Addresses are written to `deployments/1301.json`.

## Steps

Use a keystore account (`cast wallet import <name> --interactive`), never a raw key on the command line.
RPC and the explorer key come from `.env` (`WEB3_QUICKNODE_UNI_SEP`, `ETHERSCAN_TOKEN`). The whole deploy
costs ≈ 28M gas (≈ 0.00003 ETH at testnet prices).

```bash
# 0. dry run: no --broadcast, prints the gas estimate (it also writes deployments/1301.json; discard it)
forge script script/testnet/DeployTestnet.s.sol --rpc-url unichain-sepolia --account <name>

# 1. deploy. NOUSD_OWNER (registry owner and treasury) defaults to the sender; if set to another
#    address, that address must call registry.acceptOwnership().
forge script script/testnet/DeployTestnet.s.sol --rpc-url unichain-sepolia --account <name> \
  --broadcast --verify --slow

# 2. wire the test tokens' feeds into the oracle: must be sent by the oracle owner.
#    tDAI rides USDC/USD (there is no DAI/USD feed on Unichain Sepolia). Until this runs, mint reverts
#    with OracleNoOpinion; redeem is not affected.
forge script script/testnet/WireTestFeeds.s.sol --rpc-url unichain-sepolia --account <oracle-owner> --broadcast

# 3. smoke: faucet 1,000 of each test stable, mint with each, redeem half
forge script script/testnet/Smoke.s.sol --rpc-url unichain-sepolia --account <name> --broadcast
```

Then commit `deployments/1301.json` and `broadcast/DeployTestnet.s.sol/1301/run-latest.json`.

The same flow runs as a fork test, with the oracle owner pranked, so it can be checked before spending
anything: `forge test --match-path test/fork/UnichainSepoliaFork.t.sol -vv` (needs `WEB3_QUICKNODE_UNI_SEP`).
