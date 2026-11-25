// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityAmounts as AmountsMath} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {NoUSD} from "../../src/NoUSD.sol";
import {NoUSDRegistry} from "../../src/NoUSDRegistry.sol";
import {NoUSDPositionManager} from "../../src/NoUSDPositionManager.sol";

/// @dev Stablecoin mock with configurable decimals and a USDT/USDC-style blacklist.
contract StableToken is ERC20 {
    uint8 internal immutable _dec;
    mapping(address => bool) public blocked;

    constructor(string memory n, uint8 dec) ERC20(n, n) {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!blocked[to] && !blocked[from], "blocked");
        super._update(from, to, v);
    }
}

/// @dev Test-only entry that creates positions through the same internal add path mint will use, and
/// mints noUSD for the value added at par.
contract ManagerHarness is NoUSDPositionManager {
    constructor(NoUSD t, NoUSDRegistry r, IPoolManager pm) NoUSDPositionManager(t, r, pm) {}

    function seed(PoolId id, uint128 liquidity, address holder) external returns (uint256 value) {
        _sync();
        poolManager.unlock(abi.encode(Action.Add, abi.encode(id, liquidity)));
        value = _liquidityValue(id, registry.pool(id).key, positions[id], liquidity);
        token.mint(holder, value);
    }
}

/// @notice Real PoolManager, two hookless pools at par sharing one currency (A18/B6 and B6/C18), outside
/// liquidity, a registry in its launch state and the manager harness.
abstract contract ManagerFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    NoUSDRegistry internal reg;
    ManagerHarness internal mgr;
    NoUSD internal token;
    StableToken internal tA; // 18 decimals
    StableToken internal tB; // 6 decimals
    StableToken internal tC; // 18 decimals
    PoolKey internal keyAB;
    PoolKey internal keyBC;
    PoolId internal idAB;
    PoolId internal idBC;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        pm = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);
        tA = new StableToken("A", 18);
        tB = new StableToken("B", 6);
        tC = new StableToken("C", 18);

        reg = new NoUSDRegistry(address(this));
        reg.setOracle(makeAddr("oracle"));
        reg.setTreasury(treasury);
        reg.setSupplyCap(type(uint128).max);
        reg.admitToken(_c(tA), true);
        reg.admitToken(_c(tB), true);
        reg.admitToken(_c(tC), true);
        keyAB = _key(tA, tB);
        keyBC = _key(tB, tC);
        idAB = keyAB.toId();
        idBC = keyBC.toId();
        _addPool(keyAB);
        _addPool(keyBC);

        address tokenAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        mgr = new ManagerHarness(NoUSD(tokenAddr), reg, pm);
        token = new NoUSD(address(mgr));
        reg.setManager(address(mgr));

        _initPool(keyAB);
        _initPool(keyBC);
    }

    // ───────────── helpers ─────────────

    function _c(StableToken t) internal pure returns (Currency) {
        return Currency.wrap(address(t));
    }

    function _key(StableToken x, StableToken y) internal pure returns (PoolKey memory) {
        (address a, address b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        return PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 100,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function _addPool(PoolKey memory key) internal {
        int24 par = reg.parTick(key);
        reg.addPool(key, par - 100, par + 100, 1, NoUSDRegistry.PoolStatus.Active);
    }

    function _mintAndApprove(PoolKey memory key, address spender, uint256 units) internal {
        StableToken t0 = StableToken(Currency.unwrap(key.currency0));
        StableToken t1 = StableToken(Currency.unwrap(key.currency1));
        t0.mint(address(this), units * 10 ** t0.decimals());
        t1.mint(address(this), units * 10 ** t1.decimals());
        t0.approve(spender, type(uint256).max);
        t1.approve(spender, type(uint256).max);
    }

    /// @dev Initialize at par and add wide outside liquidity (≈ 1M of each token).
    function _initPool(PoolKey memory key) internal {
        int24 par = reg.parTick(key);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(par));
        _mintAndApprove(key, address(lpRouter), 10_000_000);
        _mintAndApprove(key, address(swapRouter), 10_000_000);
        uint128 l = _liquidityForValue(key, 2_000_000, par - 2_000, par + 2_000);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: par - 2_000, tickUpper: par + 2_000, liquidityDelta: int256(uint256(l)), salt: 0
            }),
            ""
        );
    }

    /// @dev Liquidity of a range at the current price worth about `units` of each side.
    function _liquidityForValue(PoolKey memory key, uint256 units, int24 lo, int24 hi) internal view returns (uint128) {
        (uint160 sp,,,) = pm.getSlot0(key.toId());
        uint8 d0 = StableToken(Currency.unwrap(key.currency0)).decimals();
        uint8 d1 = StableToken(Currency.unwrap(key.currency1)).decimals();
        return LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), units * 10 ** d0, units * 10 ** d1
        );
    }

    /// @dev Seeds the manager's position in `key` with ≈ `units` of each token for `holder`.
    function _seed(PoolKey memory key, uint256 units, address holder) internal returns (uint256 value) {
        NoUSDRegistry.PoolConfig memory cfg = reg.pool(key.toId());
        uint128 l = _liquidityForValue(key, units, cfg.tickLower, cfg.tickUpper);
        StableToken t0 = StableToken(Currency.unwrap(key.currency0));
        StableToken t1 = StableToken(Currency.unwrap(key.currency1));
        t0.mint(address(mgr), (units + 1) * 10 ** t0.decimals());
        t1.mint(address(mgr), (units + 1) * 10 ** t1.decimals());
        value = mgr.seed(key.toId(), l, holder);
    }

    /// @dev Round-trip swaps of `units` per leg, leaving the price near par and fees in the pool.
    function _churn(PoolKey memory key, uint256 units, uint256 rounds) internal {
        uint8 d0 = StableToken(Currency.unwrap(key.currency0)).decimals();
        uint8 d1 = StableToken(Currency.unwrap(key.currency1)).decimals();
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        for (uint256 i; i < rounds; ++i) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(units * 10 ** d0),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                s,
                ""
            );
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(units * 10 ** d1),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                s,
                ""
            );
        }
    }

    /// @dev Value at par of the manager's body: positions at the current price, uncollected fees, idle.
    function _bodyValue() internal view returns (uint256 v) {
        return _bodyValueAt(false);
    }

    /// @dev Same, with positions valued at the par price instead of the current one: removes the
    /// composition drift of price moves inside the range, so the invariant must hold exactly.
    function _bodyValueAtPar() internal view returns (uint256 v) {
        return _bodyValueAt(true);
    }

    function _bodyValueAt(bool atPar) internal view returns (uint256 v) {
        PoolKey[2] memory keys = [keyAB, keyBC];
        for (uint256 i; i < 2; ++i) {
            PoolId id = keys[i].toId();
            (int24 lo, int24 hi,,) = mgr.positions(id);
            if (lo == hi) continue;
            (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(id, address(mgr), lo, hi, bytes32(0));
            (uint160 sp,,,) = pm.getSlot0(id);
            if (atPar) sp = TickMath.getSqrtPriceAtTick(reg.parTick(keys[i]));
            (uint256 a0, uint256 a1) = AmountsMath.getAmountsForLiquidity(
                sp, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), l
            );
            (uint256 g0, uint256 g1) = pm.getFeeGrowthInside(id, lo, hi);
            unchecked {
                a0 += FullMath.mulDiv(g0 - last0, l, FixedPoint128.Q128);
                a1 += FullMath.mulDiv(g1 - last1, l, FixedPoint128.Q128);
            }
            v += a0 * reg.scale(keys[i].currency0) + a1 * reg.scale(keys[i].currency1);
        }
        StableToken[3] memory ts = [tA, tB, tC];
        for (uint256 i; i < 3; ++i) {
            v += mgr.idle(_c(ts[i])) * reg.scale(_c(ts[i]));
        }
    }

    function _liabilities() internal view returns (uint256) {
        return token.totalSupply() + token.totalUnclaimed() + token.treasuryAccrued() + mgr.carry();
    }

    /// @dev Value at par a holder received, by balances of the three tokens.
    function _valueOf(address who) internal view returns (uint256) {
        return tA.balanceOf(who) + tB.balanceOf(who) * 1e12 + tC.balanceOf(who);
    }
}
