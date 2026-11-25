// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityAmounts as AmountsMath} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {NoUSD} from "../../src/NoUSD.sol";
import {NoUSDRegistry} from "../../src/NoUSDRegistry.sol";
import {NoUSDPositionManager} from "../../src/NoUSDPositionManager.sol";
import {Position} from "../../src/lib/ManagerTypes.sol";

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

/// @dev unisafe-style price guard with a scripted answer: vouch, no opinion, or revert.
contract MockOracle {
    enum Mode {
        Vouch,
        NoOpinion,
        Revert
    }

    Mode public mode;

    error SpotPriceOutOfBounds();

    function setMode(Mode m) external {
        mode = m;
    }

    function check(PoolKey calldata, bool, uint256, uint256) external view returns (bool) {
        if (mode == Mode.Revert) revert SpotPriceOutOfBounds();
        return mode == Mode.Vouch;
    }
}

/// @dev Test-only entry that creates positions through the same internal add path mint will use, and
/// mints noUSD for the value added at par.
contract ManagerHarness is NoUSDPositionManager {
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    constructor(NoUSD t, NoUSDRegistry r, IPoolManager pm) NoUSDPositionManager(t, r, pm) {}

    /// @dev Adds `liquidity` paid from the harness's own token balance and mints noUSD for its value.
    function seed(PoolId id, uint128 liquidity, address holder) external returns (uint256 value) {
        _syncNow();
        poolManager.unlock(abi.encode(Action.Add, abi.encode(id, liquidity)));
        value = _liquidityValue(id, positions[id], liquidity);
        token.mint(holder, value);
    }

    function _addForTest(bytes memory data) internal override returns (bytes memory) {
        (PoolId id, uint128 liquidity) = abi.decode(data, (PoolId, uint128));
        Position storage pos = _ensurePosition(id, _cfg(id));
        _add(id, pos, liquidity);
        _payFromBalance(pos.currency0);
        _payFromBalance(pos.currency1);
        return "";
    }

    /// @dev Settles a debt from the harness's token balance; a credit becomes idle.
    function _payFromBalance(Currency c) internal {
        int256 d = poolManager.currencyDelta(address(this), c);
        if (d < 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(poolManager), uint256(-d));
            poolManager.settle();
        } else {
            _resolve(c, 0, address(0));
        }
    }
}

/// @notice Real PoolManager, two hookless pools at par sharing one currency (A18/B6 and B6/C18), outside
/// liquidity, a registry in its launch state and the manager harness.
abstract contract ManagerFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    MockOracle internal oracle;
    mapping(PoolId => uint160) internal creditPrice;
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
        oracle = new MockOracle();
        reg.setOracle(address(oracle));
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

    /// @dev Initialize at par and add outside liquidity of ≈ 2M of each token within ±2 % of par, like the
    /// concentrated depth of a live stable pool.
    function _initPool(PoolKey memory key) internal {
        int24 par = reg.parTick(key);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(par));
        _mintAndApprove(key, address(lpRouter), 10_000_000);
        _mintAndApprove(key, address(swapRouter), 10_000_000);
        uint128 l = _liquidityForValue(key, 2_000_000, par - 200, par + 200);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: par - 200, tickUpper: par + 200, liquidityDelta: int256(uint256(l)), salt: 0
            }),
            ""
        );
        creditPrice[key.toId()] = TickMath.getSqrtPriceAtTick(par);
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

    /// @dev Same, with each position valued at the pool price of the last credit (seed or mint) instead of
    /// the current one. Liabilities were credited at that price, so no-value-created must hold exactly;
    /// any other price adds the composition drift of spec §6. (Valuing at par would be wrong: at a fixed
    /// valuation price an LP position is worth least when the pool sits exactly at that price.)
    function _bodyValueAtCredit() internal view returns (uint256 v) {
        return _bodyValueAt(true);
    }

    /// @dev Records the current pool prices as the credit prices (call after a mint).
    function _markCredit() internal {
        (uint160 a,,,) = pm.getSlot0(idAB);
        (uint160 b,,,) = pm.getSlot0(idBC);
        creditPrice[idAB] = a;
        creditPrice[idBC] = b;
    }

    function _bodyValueAt(bool atCredit) internal view returns (uint256 v) {
        PoolKey[2] memory keys = [keyAB, keyBC];
        for (uint256 i; i < 2; ++i) {
            PoolId id = keys[i].toId();
            (int24 lo, int24 hi,,,,,,,,) = mgr.positions(id);
            if (lo == hi) continue;
            (uint128 l, uint256 last0, uint256 last1) = pm.getPositionInfo(id, address(mgr), lo, hi, bytes32(0));
            (uint160 sp,,,) = pm.getSlot0(id);
            if (atCredit) sp = creditPrice[id];
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

    /// @dev Queue, wait out the timelock and execute a registry call (the test contract owns the registry).
    function _timelocked(bytes memory data) internal {
        reg.queue(data);
        skip(48 hours);
        reg.execute(data);
    }

    /// @dev Mint `units` whole tokens of `t` for `who` (funds and approves first).
    function _mint(StableToken t, uint256 units, address who) internal returns (uint256 out) {
        uint256 amount = units * 10 ** t.decimals();
        t.mint(who, amount);
        vm.startPrank(who);
        t.approve(address(mgr), amount);
        out = mgr.mint(_c(t), amount, 0, who, type(uint256).max);
        vm.stopPrank();
        _markCredit();
    }

    /// @dev Rounding dust allowed when liquidity is (re)added: v4 charges rounded-up amounts, the body is
    /// measured rounded down, and one unit of liquidity can be worth ~1e9 wei of an 18-decimal token next
    /// to a 6-decimal one. 1e13 is 1e-5 of a cent.
    uint256 internal constant DUST = 1e13;

    function _assertSolvent() internal view {
        assertGe(_bodyValueAtCredit() + DUST, _liabilities(), "body covers liabilities at the credit price");
    }

    function _liabilities() internal view returns (uint256) {
        return token.totalSupply() + token.totalUnclaimed() + token.treasuryAccrued() + mgr.carry();
    }

    /// @dev Value at par a holder received, by balances of the three tokens.
    function _valueOf(address who) internal view returns (uint256) {
        return tA.balanceOf(who) + tB.balanceOf(who) * 1e12 + tC.balanceOf(who);
    }
}
