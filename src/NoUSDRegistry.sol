// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {INoUSDPositionManager} from "./interfaces/INoUSDPositionManager.sol";

/// @title NoUSDRegistry
/// @notice Admitted tokens, registered pools, parameters with hard caps, oracle and treasury of one noUSD
/// deployment (docs/spec.md §4). Owned by a Safe through Ownable2Step.
/// Tightening changes apply at once; every loosening change must first be queued and can be executed 48 h
/// later, so holders can leave before it takes effect. Until the manager is wired (deployment), the owner
/// configures without delay: nothing is at stake yet.
/// @dev Each setter decides itself whether a call tightens. A loosening call is accepted only from this
/// contract, which happens through `execute` of a matured queued call.
contract NoUSDRegistry is Ownable2Step {
    using PoolIdLibrary for PoolKey;

    enum PoolStatus {
        None,
        Active,
        WithdrawOnly
    }

    struct TokenConfig {
        bool admitted;
        bool mintable;
        uint8 decimals;
    }

    struct PoolConfig {
        PoolKey key;
        int24 tickLower; // range preset around par, multiple of tickSpacing
        int24 tickUpper;
        uint16 maxShareBps;
        uint16 weight;
        PoolStatus status;
    }

    /// @notice Everything the manager reads on each call.
    struct Params {
        uint32 burnDelay;
        uint16 mintFeeBps;
        uint16 protocolFeeBps;
        uint16 depegBps;
        uint16 maxPoolShareBps; // default share cap for new pools
        uint32 selectionWindow;
        bool mintPaused;
        uint128 compoundThreshold; // value at par, 18 decimals
        uint128 supplyCap; // max totalSupply after a mint, 18 decimals
        address oracle;
        address treasury;
    }

    /// @notice The parameters packed in the first storage slot of Params: what the manager reads on every
    /// sync, burn and mint, at the cost of one SLOAD.
    struct CoreParams {
        uint32 burnDelay;
        uint16 mintFeeBps;
        uint16 protocolFeeBps;
        uint16 depegBps;
        uint16 maxPoolShareBps;
        uint32 selectionWindow;
        bool mintPaused;
    }

    /// @notice Delay for every loosening change (spec §4.4).
    uint256 public constant TIMELOCK = 48 hours;
    /// @notice Maximum number of registered pools (spec §4.2).
    uint256 public constant MAX_POOLS = 8;

    // Hard caps on parameters (spec §4.3).
    uint256 public constant MAX_BURN_DELAY = 7 days;
    uint256 public constant MAX_MINT_FEE_BPS = 50;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    uint256 public constant MIN_DEPEG_BPS = 1;
    uint256 public constant MAX_DEPEG_BPS = 200;
    uint256 public constant MAX_POOL_SHARE_BPS = 5_000;
    uint256 public constant MIN_SELECTION_WINDOW = 1 days;
    uint256 public constant MAX_SELECTION_WINDOW = 30 days;

    /// @notice The position manager called by `retirePool`; set once, which also ends the setup phase.
    address public manager;

    Params internal _params;
    mapping(Currency => TokenConfig) internal _tokens;
    mapping(PoolId => PoolConfig) internal _pools;
    PoolId[] internal _poolIds;

    /// @notice Earliest execution time of a queued call, by keccak256 of its calldata; 0 if not queued.
    mapping(bytes32 => uint256) public queuedAt;

    event ManagerSet(address manager);
    event ChangeQueued(bytes32 indexed hash, bytes data, uint256 eta);
    event ChangeExecuted(bytes32 indexed hash);
    event ChangeCancelled(bytes32 indexed hash);
    event ParamChanged(bytes32 indexed name, uint256 oldValue, uint256 newValue);
    event TokenAdmitted(Currency indexed token, uint8 decimals, bool mintable);
    event MintableChanged(Currency indexed token, bool mintable);
    event PoolAdded(PoolId indexed id, PoolKey key, int24 tickLower, int24 tickUpper);
    event PoolRemoved(PoolId indexed id);
    event PoolStatusChanged(PoolId indexed id, PoolStatus oldStatus, PoolStatus newStatus);
    event PoolRangeChanged(PoolId indexed id, int24 tickLower, int24 tickUpper);
    event PoolShareChanged(PoolId indexed id, uint16 oldBps, uint16 newBps);
    event PoolWeightChanged(PoolId indexed id, uint16 oldWeight, uint16 newWeight);

    error ManagerAlreadySet();
    error ZeroAddress();
    error CapExceeded();
    error TimelockRequired();
    error TimelockNotReady(uint256 eta);
    error NotQueued();
    error AlreadyQueued();
    error RenounceDisabled();
    error TokenAlreadyAdmitted();
    error TokenNotAdmitted(Currency token);
    error UnsupportedToken();
    error PoolHasHooks();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error TooManyPools();
    error InvalidRange();
    error InvalidStatus();
    error PositionNotEmpty();
    error MustBeWithdrawOnly();

    /// @dev Owner directly for tightening; this contract (via `execute`) for anything.
    modifier onlyGovernance() {
        if (msg.sender != owner() && msg.sender != address(this)) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    /// @param owner_ The Safe (or the deployer, who hands over with Ownable2Step after setup).
    constructor(address owner_) Ownable(owner_) {
        _params.depegBps = 50;
        _params.maxPoolShareBps = 3_000;
        _params.selectionWindow = 7 days;
        // supplyCap 0 and no oracle: nothing can be minted until both are configured.
    }

    // ───────────────────────────── setup and timelock ─────────────────────────────

    /// @notice Wires the manager once and ends the setup phase: from now on loosening needs the timelock.
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    /// @notice Queues a loosening call (calldata of one of this contract's setters) for execution after
    /// TIMELOCK.
    function queue(bytes calldata data) external onlyOwner returns (bytes32 hash) {
        hash = keccak256(data);
        if (queuedAt[hash] != 0) revert AlreadyQueued();
        uint256 eta = block.timestamp + TIMELOCK;
        queuedAt[hash] = eta;
        emit ChangeQueued(hash, data, eta);
    }

    /// @notice Executes a matured queued call.
    function execute(bytes calldata data) external onlyOwner {
        bytes32 hash = keccak256(data);
        uint256 eta = queuedAt[hash];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TimelockNotReady(eta);
        delete queuedAt[hash];
        emit ChangeExecuted(hash);
        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function cancel(bytes32 hash) external onlyOwner {
        if (queuedAt[hash] == 0) revert NotQueued();
        delete queuedAt[hash];
        emit ChangeCancelled(hash);
    }

    /// @notice Disabled: without an owner nobody could tighten in an emergency (retire a pool, pause mint).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ───────────────────────────── parameters (spec §4.3) ─────────────────────────────

    /// @notice Hurts holders either way, so always timelocked (spec §4.4).
    function setBurnDelay(uint32 value) external onlyGovernance {
        if (value > MAX_BURN_DELAY) revert CapExceeded();
        _requireTimelock(false);
        emit ParamChanged("burnDelay", _params.burnDelay, value);
        _params.burnDelay = value;
    }

    /// @notice Hurts holders either way, so always timelocked (spec §4.4).
    function setMintFeeBps(uint16 value) external onlyGovernance {
        if (value > MAX_MINT_FEE_BPS) revert CapExceeded();
        _requireTimelock(false);
        emit ParamChanged("mintFeeBps", _params.mintFeeBps, value);
        _params.mintFeeBps = value;
    }

    function setProtocolFeeBps(uint16 value) external onlyGovernance {
        if (value > MAX_PROTOCOL_FEE_BPS) revert CapExceeded();
        _requireTimelock(false);
        emit ParamChanged("protocolFeeBps", _params.protocolFeeBps, value);
        _params.protocolFeeBps = value;
    }

    /// @notice Lowering tightens the depeg breaker and applies at once.
    function setDepegBps(uint16 value) external onlyGovernance {
        if (value < MIN_DEPEG_BPS || value > MAX_DEPEG_BPS) revert CapExceeded();
        _requireTimelock(value <= _params.depegBps);
        emit ParamChanged("depegBps", _params.depegBps, value);
        _params.depegBps = value;
    }

    /// @notice Default share cap for pools added later. Lowering applies at once.
    function setMaxPoolShareBps(uint16 value) external onlyGovernance {
        if (value > MAX_POOL_SHARE_BPS) revert CapExceeded();
        _requireTimelock(value <= _params.maxPoolShareBps);
        emit ParamChanged("maxPoolShareBps", _params.maxPoolShareBps, value);
        _params.maxPoolShareBps = value;
    }

    function setSelectionWindow(uint32 value) external onlyGovernance {
        if (value < MIN_SELECTION_WINDOW || value > MAX_SELECTION_WINDOW) revert CapExceeded();
        _requireTimelock(false);
        emit ParamChanged("selectionWindow", _params.selectionWindow, value);
        _params.selectionWindow = value;
    }

    /// @notice Raising the threshold only delays compounding and applies at once.
    function setCompoundThreshold(uint128 value) external onlyGovernance {
        _requireTimelock(value >= _params.compoundThreshold);
        emit ParamChanged("compoundThreshold", _params.compoundThreshold, value);
        _params.compoundThreshold = value;
    }

    /// @notice Lowering the cap applies at once; burn is never affected.
    function setSupplyCap(uint128 value) external onlyGovernance {
        _requireTimelock(value <= _params.supplyCap);
        emit ParamChanged("supplyCap", _params.supplyCap, value);
        _params.supplyCap = value;
    }

    function setOracle(address value) external onlyGovernance {
        if (value == address(0)) revert ZeroAddress();
        _requireTimelock(false);
        emit ParamChanged("oracle", uint160(_params.oracle), uint160(value));
        _params.oracle = value;
    }

    function setTreasury(address value) external onlyGovernance {
        if (value == address(0)) revert ZeroAddress();
        _requireTimelock(false);
        emit ParamChanged("treasury", uint160(_params.treasury), uint160(value));
        _params.treasury = value;
    }

    /// @notice Stops all mints at once. Burn and claim cannot be paused.
    function pauseMint() external onlyGovernance {
        emit ParamChanged("mintPaused", _params.mintPaused ? 1 : 0, 1);
        _params.mintPaused = true;
    }

    function unpauseMint() external onlyGovernance {
        _requireTimelock(false);
        emit ParamChanged("mintPaused", _params.mintPaused ? 1 : 0, 0);
        _params.mintPaused = false;
    }

    // ───────────────────────────── tokens (spec §4.1) ─────────────────────────────

    /// @notice Admits a token that may appear in registered pools. Native ETH and tokens with more than 18
    /// decimals are refused; fee-on-transfer and rebasing tokens must not be admitted (not checkable).
    function admitToken(Currency token, bool mintable) external onlyGovernance {
        if (token.isAddressZero()) revert UnsupportedToken();
        if (_tokens[token].admitted) revert TokenAlreadyAdmitted();
        _requireTimelock(false);
        uint8 dec = IERC20Metadata(Currency.unwrap(token)).decimals();
        if (dec > 18) revert UnsupportedToken();
        _tokens[token] = TokenConfig({admitted: true, mintable: mintable, decimals: dec});
        emit TokenAdmitted(token, dec, mintable);
    }

    /// @notice Disabling mint with a token applies at once; enabling is timelocked.
    function setMintable(Currency token, bool mintable) external onlyGovernance {
        TokenConfig storage t = _tokens[token];
        if (!t.admitted) revert TokenNotAdmitted(token);
        _requireTimelock(!mintable);
        t.mintable = mintable;
        emit MintableChanged(token, mintable);
    }

    // ───────────────────────────── pools (spec §4.2) ─────────────────────────────

    /// @notice Registers an existing hookless v4 pool of two admitted tokens with a range preset that
    /// contains par. Share cap starts at the default `maxPoolShareBps`.
    function addPool(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint16 weight, PoolStatus status)
        external
        onlyGovernance
    {
        if (address(key.hooks) != address(0)) revert PoolHasHooks();
        if (!_tokens[key.currency0].admitted) revert TokenNotAdmitted(key.currency0);
        if (!_tokens[key.currency1].admitted) revert TokenNotAdmitted(key.currency1);
        if (status == PoolStatus.None) revert InvalidStatus();
        PoolId id = key.toId();
        if (_pools[id].status != PoolStatus.None) revert PoolAlreadyRegistered();
        if (_poolIds.length >= MAX_POOLS) revert TooManyPools();
        _checkRange(key, tickLower, tickUpper);
        _requireTimelock(false);

        _pools[id] = PoolConfig({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxShareBps: _params.maxPoolShareBps,
            weight: weight,
            status: status
        });
        _poolIds.push(id);
        emit PoolAdded(id, key, tickLower, tickUpper);
        emit PoolStatusChanged(id, PoolStatus.None, status);
    }

    /// @notice WithdrawOnly applies at once; Active is timelocked.
    function setPoolStatus(PoolId id, PoolStatus status) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        if (status == PoolStatus.None) revert InvalidStatus();
        _requireTimelock(status == PoolStatus.WithdrawOnly);
        emit PoolStatusChanged(id, p.status, status);
        p.status = status;
    }

    /// @notice New range preset; the manager moves the position with the permissionless `applyRange`.
    function setPoolRange(PoolId id, int24 tickLower, int24 tickUpper) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        _checkRange(p.key, tickLower, tickUpper);
        _requireTimelock(false);
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        emit PoolRangeChanged(id, tickLower, tickUpper);
    }

    /// @notice Lowering the share cap of a pool applies at once.
    function setPoolShare(PoolId id, uint16 bps) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        if (bps > MAX_POOL_SHARE_BPS) revert CapExceeded();
        _requireTimelock(bps <= p.maxShareBps);
        emit PoolShareChanged(id, p.maxShareBps, bps);
        p.maxShareBps = bps;
    }

    function setPoolWeight(PoolId id, uint16 weight) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        _requireTimelock(false);
        emit PoolWeightChanged(id, p.weight, weight);
        p.weight = weight;
    }

    /// @notice Emergency exit from a pool, at once: marks it WithdrawOnly and has the manager move all of
    /// its liquidity to idle balances (after a sync). Funds stay with holders.
    function retirePool(PoolId id) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        emit PoolStatusChanged(id, p.status, PoolStatus.WithdrawOnly);
        p.status = PoolStatus.WithdrawOnly;
        if (manager != address(0)) INoUSDPositionManager(manager).retire(id);
    }

    /// @notice Drops a WithdrawOnly pool whose position is empty, freeing its slot. At once: it changes
    /// nothing for holders.
    function removePool(PoolId id) external onlyGovernance {
        PoolConfig storage p = _registered(id);
        if (p.status != PoolStatus.WithdrawOnly) revert MustBeWithdrawOnly();
        if (manager != address(0) && !INoUSDPositionManager(manager).isPositionEmpty(id)) {
            revert PositionNotEmpty();
        }
        delete _pools[id];
        uint256 n = _poolIds.length;
        for (uint256 i; i < n; ++i) {
            if (PoolId.unwrap(_poolIds[i]) == PoolId.unwrap(id)) {
                _poolIds[i] = _poolIds[n - 1];
                _poolIds.pop();
                break;
            }
        }
        emit PoolRemoved(id);
    }

    // ───────────────────────────── views ─────────────────────────────

    function params() external view returns (Params memory) {
        return _params;
    }

    function coreParams() external view returns (CoreParams memory c) {
        Params storage p = _params;
        c = CoreParams({
            burnDelay: p.burnDelay,
            mintFeeBps: p.mintFeeBps,
            protocolFeeBps: p.protocolFeeBps,
            depegBps: p.depegBps,
            maxPoolShareBps: p.maxPoolShareBps,
            selectionWindow: p.selectionWindow,
            mintPaused: p.mintPaused
        });
    }

    function tokens(Currency token) external view returns (TokenConfig memory) {
        return _tokens[token];
    }

    function pool(PoolId id) external view returns (PoolConfig memory) {
        return _pools[id];
    }

    function poolIds() external view returns (PoolId[] memory) {
        return _poolIds;
    }

    function poolCount() external view returns (uint256) {
        return _poolIds.length;
    }

    /// @notice 10**(18 − decimals) of an admitted token (spec §3); 0 if not admitted.
    function scale(Currency token) external view returns (uint256) {
        TokenConfig memory t = _tokens[token];
        return t.admitted ? 10 ** (18 - t.decimals) : 0;
    }

    /// @notice The tick of the par price (1 unit of currency0 = 1 unit of currency1) of a pool.
    function parTick(PoolKey memory key) public view returns (int24) {
        uint8 d0 = _tokens[key.currency0].decimals;
        uint8 d1 = _tokens[key.currency1].decimals;
        // Raw price currency1 per currency0 at par is 10**(d1 − d0); sqrtPriceX96 = sqrt(price · 2^192).
        uint256 sqrtPriceX96 = Math.sqrt(Math.mulDiv(1 << 192, 10 ** d1, 10 ** d0));
        return TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96));
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev Loosening calls pass only through `execute` (msg.sender == this) or during setup.
    function _requireTimelock(bool tightening) internal view {
        if (tightening || manager == address(0) || msg.sender == address(this)) return;
        revert TimelockRequired();
    }

    function _registered(PoolId id) internal view returns (PoolConfig storage p) {
        p = _pools[id];
        if (p.status == PoolStatus.None) revert PoolNotRegistered();
    }

    function _checkRange(PoolKey memory key, int24 tickLower, int24 tickUpper) internal view {
        int24 spacing = key.tickSpacing;
        if (
            tickLower >= tickUpper || tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK
                || tickLower % spacing != 0 || tickUpper % spacing != 0
        ) revert InvalidRange();
        int24 par = parTick(key);
        if (par < tickLower || par >= tickUpper) revert InvalidRange();
    }
}
