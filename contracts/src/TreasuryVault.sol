// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TreasuryVault
/// @notice A project treasury that nobody owns. Anyone can deposit tokens or ETH. A manager can only announce a
///         withdrawal; it executes after a public delay, only to an allowed destination, and no more than a fixed
///         share of the balance can leave per week. Every rule can only become stricter after creation. There is no
///         admin, no pause, no upgrade and no emergency withdrawal. The weekly share can never exceed 25%.
/// @dev `address(0)` stands for ETH everywhere. The weekly cap is measured per asset, per fixed 7-day epoch, as
///      `rateBps` of the balance seen by the first withdrawal executed in that epoch.
contract TreasuryVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant ETH = address(0);
    uint256 public constant EPOCH = 7 days;
    uint256 public constant GRACE = 14 days;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant BPS = 10_000;
    /// @notice At most 25% of a treasury can leave per week.
    uint16 public constant MAX_RATE_BPS = 2_500;

    /// @notice The project this treasury belongs to (informational: the radar files the vault under this token).
    address public immutable projectToken;

    address public manager;
    uint64 public delay;
    uint16 public rateBps;
    /// @notice True when withdrawals may only go to the destinations listed below.
    bool public restricted;

    address public pendingManager;
    uint64 public pendingManagerEta;

    struct Withdrawal {
        address asset;
        address to;
        uint256 amount;
        uint64 queuedAt;
        bool done; // executed or cancelled
    }

    Withdrawal[] public withdrawals;

    mapping(address => bool) public isDestination;
    address[] internal _destinations;

    struct Window {
        uint64 epoch;
        uint256 cap;
        uint256 spent;
    }

    mapping(address => Window) public windows;

    event Deposited(address indexed asset, address indexed from, uint256 amount);
    event Queued(uint256 indexed id, address indexed asset, address indexed to, uint256 amount, uint64 eta);
    event Cancelled(uint256 indexed id);
    event Executed(uint256 indexed id, address indexed asset, address indexed to, uint256 amount);
    event DelayIncreased(uint64 oldDelay, uint64 newDelay);
    event RateDecreased(uint16 oldBps, uint16 newBps);
    event DestinationsRestricted(address[] destinations);
    event DestinationRemoved(address indexed destination);
    event ManagerProposed(address indexed current, address indexed proposed, uint64 eta);
    event ManagerCancelled(address indexed proposed);
    event ManagerChanged(address indexed oldManager, address indexed newManager);

    error NotManager();
    error NotPendingManager();
    error ZeroAddress();
    error ZeroAmount();
    error BadDelay();
    error BadRate();
    error NotAllowed(address to);
    error UnknownWithdrawal();
    error AlreadyDone();
    error TooEarly(uint64 eta);
    error Expired();
    error OverWeeklyCap(uint256 available);
    error NoProposal();
    error AlreadyRestricted();
    error NotRestricted();
    error NotListed();
    error EthTransferFailed();

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(address projectToken_, address manager_, uint64 delay_, uint16 rateBps_, address[] memory destinations_) {
        if (manager_ == address(0)) revert ZeroAddress();
        if (delay_ > MAX_DELAY) revert BadDelay();
        if (rateBps_ == 0 || rateBps_ > MAX_RATE_BPS) revert BadRate();
        projectToken = projectToken_;
        manager = manager_;
        delay = delay_;
        rateBps = rateBps_;
        if (destinations_.length > 0) _restrict(destinations_);
    }

    // ---------- deposits ----------

    receive() external payable {
        emit Deposited(ETH, msg.sender, msg.value);
    }

    /// @notice Deposits a token. Sending tokens straight to the vault works too; this only adds an event.
    function deposit(IERC20 asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(address(asset), msg.sender, asset.balanceOf(address(this)) - before);
    }

    // ---------- withdrawals: announced, delayed, capped ----------

    /// @notice Announces a withdrawal. It can execute once the delay has passed, by anyone, within the grace period.
    function queue(address asset, address to, uint256 amount) external onlyManager returns (uint256 id) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (restricted && !isDestination[to]) revert NotAllowed(to);
        id = withdrawals.length;
        withdrawals.push(Withdrawal(asset, to, amount, uint64(block.timestamp), false));
        emit Queued(id, asset, to, amount, uint64(block.timestamp) + delay);
    }

    function cancel(uint256 id) external onlyManager {
        Withdrawal storage w = _get(id);
        if (w.done) revert AlreadyDone();
        w.done = true;
        emit Cancelled(id);
    }

    /// @notice Executes an announced withdrawal. Anyone can call it; the funds only go to the announced destination.
    /// @dev The current delay and destination list apply, so tightening either also holds back queued withdrawals.
    function execute(uint256 id) external nonReentrant {
        Withdrawal storage w = _get(id);
        if (w.done) revert AlreadyDone();
        uint64 due = w.queuedAt + delay;
        if (block.timestamp < due) revert TooEarly(due);
        if (block.timestamp > due + GRACE) revert Expired();
        if (restricted && !isDestination[w.to]) revert NotAllowed(w.to);

        Window storage win = windows[w.asset];
        uint64 epoch = uint64(block.timestamp / EPOCH);
        if (win.epoch != epoch) {
            win.epoch = epoch;
            win.cap = (_balance(w.asset) * rateBps) / BPS;
            win.spent = 0;
        }
        uint256 available = win.cap - win.spent;
        if (w.amount > available) revert OverWeeklyCap(available);
        win.spent += w.amount;
        w.done = true;

        if (w.asset == ETH) {
            (bool ok,) = w.to.call{value: w.amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(w.asset).safeTransfer(w.to, w.amount);
        }
        emit Executed(id, w.asset, w.to, w.amount);
    }

    // ---------- rules: they can only get stricter ----------

    function increaseDelay(uint64 newDelay) external onlyManager {
        if (newDelay <= delay || newDelay > MAX_DELAY) revert BadDelay();
        emit DelayIncreased(delay, newDelay);
        delay = newDelay;
    }

    function decreaseRate(uint16 newBps) external onlyManager {
        if (newBps == 0 || newBps >= rateBps) revert BadRate();
        emit RateDecreased(rateBps, newBps);
        rateBps = newBps;
    }

    /// @notice Limits an open vault to a list of destinations. Only possible once, and the list can then only shrink.
    function restrictDestinations(address[] calldata list) external onlyManager {
        if (restricted) revert AlreadyRestricted();
        if (list.length == 0) revert NotListed();
        _restrict(list);
    }

    function removeDestination(address destination) external onlyManager {
        if (!restricted) revert NotRestricted();
        if (!isDestination[destination]) revert NotListed();
        // Keep at least one destination, or the treasury would be frozen for good.
        if (_destinations.length == 1) revert NotListed();
        isDestination[destination] = false;
        uint256 n = _destinations.length;
        for (uint256 i; i < n; ++i) {
            if (_destinations[i] == destination) {
                _destinations[i] = _destinations[n - 1];
                _destinations.pop();
                break;
            }
        }
        emit DestinationRemoved(destination);
    }

    // ---------- changing the manager: proposed, public, then delayed ----------

    function proposeManager(address proposed) external onlyManager {
        if (proposed == address(0)) revert ZeroAddress();
        pendingManager = proposed;
        pendingManagerEta = uint64(block.timestamp) + delay;
        emit ManagerProposed(manager, proposed, pendingManagerEta);
    }

    function cancelManager() external onlyManager {
        address proposed = pendingManager;
        if (proposed == address(0)) revert NoProposal();
        delete pendingManager;
        delete pendingManagerEta;
        emit ManagerCancelled(proposed);
    }

    function acceptManager() external {
        address proposed = pendingManager;
        if (proposed == address(0)) revert NoProposal();
        if (msg.sender != proposed) revert NotPendingManager();
        if (block.timestamp < pendingManagerEta) revert TooEarly(pendingManagerEta);
        emit ManagerChanged(manager, proposed);
        manager = proposed;
        delete pendingManager;
        delete pendingManagerEta;
    }

    // ---------- views for the radar ----------

    function destinations() external view returns (address[] memory) {
        return _destinations;
    }

    function withdrawalCount() external view returns (uint256) {
        return withdrawals.length;
    }

    /// @notice What can still leave this epoch for `asset`, if a withdrawal executed right now.
    function availableThisWeek(address asset) external view returns (uint256) {
        Window memory win = windows[asset];
        if (win.epoch != uint64(block.timestamp / EPOCH)) return (_balance(asset) * rateBps) / BPS;
        return win.cap - win.spent;
    }

    // ---------- internals ----------

    function _restrict(address[] memory list) internal {
        restricted = true;
        for (uint256 i; i < list.length; ++i) {
            address d = list[i];
            if (d == address(0)) revert ZeroAddress();
            if (isDestination[d]) continue;
            isDestination[d] = true;
            _destinations.push(d);
        }
        emit DestinationsRestricted(_destinations);
    }

    function _get(uint256 id) internal view returns (Withdrawal storage) {
        if (id >= withdrawals.length) revert UnknownWithdrawal();
        return withdrawals[id];
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == ETH ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }
}
