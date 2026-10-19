// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingVault} from "./VestingVault.sol";
import {TreasuryVault} from "./TreasuryVault.sol";

/// @title VaultFactory
/// @notice Creates IMD Vaults and keeps a public registry of them. The factory has no owner and holds no funds: it
///         only deploys vaults and records them for anyone (and IMD RADAR) to read.
/// @dev The service fee is 5 IMD per project, paid once, to IMD RADAR's public wallet (it funds the radar's servers
///      and swarm jobs). IMD lives on Ethereum, so:
///      - On Ethereum (`imd` set), a project's first vault charges the fee for its token.
///      - On other chains (`imd` is zero, e.g. Robinhood), vaults are free to create; the project pays on Ethereum with
///        `payFor(chainId, token)`, and the radar reads `feePaid` there before granting its seal.
contract VaultFactory {
    using SafeERC20 for IERC20;

    uint256 public constant FEE = 5e18;
    uint64 public constant BENEFICIARY_DELAY = 7 days;
    uint64 public constant MIN_DELAY = 1 days;

    /// @notice IMD on this chain, or zero where vaults are free and the fee is paid on Ethereum.
    IERC20 public immutable imd;
    /// @notice IMD RADAR's public wallet, which receives the fees.
    address public immutable feeRecipient;

    address[] public allVaults;
    mapping(address => bool) public isVault;
    mapping(address => address[]) internal _vaultsByToken;
    /// @notice chainId => project token => whether the one-time fee has been paid.
    mapping(uint256 => mapping(address => bool)) public feePaid;

    event FeePaid(uint256 indexed chainId, address indexed token, address indexed payer, uint256 amount);
    event VestingCreated(
        address indexed vault,
        address indexed token,
        address indexed beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    );
    event TreasuryCreated(
        address indexed vault,
        address indexed projectToken,
        address indexed manager,
        uint64 delay,
        uint16 rateBps,
        address[] destinations
    );

    error ZeroAddress();
    error ZeroAmount();
    error BadDelay();
    error NoFeeOnThisChain();
    error AlreadyPaid();

    constructor(IERC20 imd_, address feeRecipient_) {
        if (address(imd_) != address(0) && feeRecipient_ == address(0)) revert ZeroAddress();
        imd = imd_;
        feeRecipient = feeRecipient_;
    }

    /// @notice Locks `amount` of `token` in a new vesting vault: nothing before `start + cliff`, then linear over
    ///         `duration` (at least 4 weeks). The caller must have approved this factory for the tokens and, for a
    ///         project's first vault on Ethereum, for 5 IMD.
    function createVesting(IERC20 token, address beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        external
        returns (VestingVault vault)
    {
        if (amount == 0) revert ZeroAmount();
        _chargeOnce(address(token));
        vault = new VestingVault(token, beneficiary, start, cliff, duration, BENEFICIARY_DELAY);
        token.safeTransferFrom(msg.sender, address(vault), amount);
        _register(address(vault), address(token));
        emit VestingCreated(address(vault), address(token), beneficiary, amount, start, cliff, duration);
    }

    /// @notice Creates a treasury vault for `projectToken`. Fund it afterwards by sending tokens or ETH to it.
    ///         An empty `destinations` list leaves it open to any destination (it can be restricted later, never
    ///         reopened). For a project's first vault on Ethereum the caller must have approved this factory for 5 IMD.
    function createTreasury(address projectToken, address manager, uint64 delay, uint16 rateBps, address[] calldata destinations)
        external
        returns (TreasuryVault vault)
    {
        if (delay < MIN_DELAY) revert BadDelay();
        _chargeOnce(projectToken);
        vault = new TreasuryVault(projectToken, manager, delay, rateBps, destinations);
        _register(address(vault), projectToken);
        emit TreasuryCreated(address(vault), projectToken, manager, delay, rateBps, destinations);
    }

    /// @notice Pays the one-time fee for a project on another chain (for example a Robinhood token), in IMD on
    ///         Ethereum. Anyone can pay for any project.
    function payFor(uint256 chainId, address token) external {
        if (address(imd) == address(0)) revert NoFeeOnThisChain();
        if (token == address(0)) revert ZeroAddress();
        if (feePaid[chainId][token]) revert AlreadyPaid();
        _pay(chainId, token);
    }

    function vaultsByToken(address token) external view returns (address[] memory) {
        return _vaultsByToken[token];
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function _chargeOnce(address token) internal {
        if (address(imd) == address(0) || feePaid[block.chainid][token]) return;
        _pay(block.chainid, token);
    }

    function _pay(uint256 chainId, address token) internal {
        feePaid[chainId][token] = true;
        imd.safeTransferFrom(msg.sender, feeRecipient, FEE);
        emit FeePaid(chainId, token, msg.sender, FEE);
    }

    function _register(address vault, address token) internal {
        allVaults.push(vault);
        isVault[vault] = true;
        _vaultsByToken[token].push(vault);
    }
}
