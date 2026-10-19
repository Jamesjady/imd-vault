// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VestingVault
/// @notice Holds one token and releases it to a beneficiary on a schedule: nothing during the cliff, then linearly
///         over `duration`. No schedule can unlock more than 25% of the tokens in any week. Nobody owns this contract. The schedule can only get longer, and a new beneficiary takes
///         over only after a public delay. There is no admin, no pause and no emergency withdrawal.
/// @dev The amount under vesting is this contract's balance plus what it already released, so tokens that charge
///      a transfer fee and later top-ups are both accounted for: everything that arrives vests on the same schedule.
contract VestingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The shortest linear unlock allowed: 4 weeks, so at most 25% of the tokens unlock in any 7 days.
    uint64 public constant MIN_DURATION = 28 days;

    IERC20 public immutable token;
    uint64 public immutable start;
    uint64 public immutable cliff; // seconds after start before anything unlocks
    uint64 public immutable beneficiaryDelay;

    uint64 public duration; // length of the linear unlock after the cliff; can only grow
    address public beneficiary;
    uint256 public released;

    address public pendingBeneficiary;
    uint64 public pendingBeneficiaryEta;

    event Released(address indexed beneficiary, uint256 amount);
    event DurationExtended(uint64 oldDuration, uint64 newDuration);
    event BeneficiaryProposed(address indexed current, address indexed proposed, uint64 eta);
    event BeneficiaryCancelled(address indexed proposed);
    event BeneficiaryChanged(address indexed oldBeneficiary, address indexed newBeneficiary);
    event Recovered(address indexed otherToken, address indexed to, uint256 amount);

    error NotBeneficiary();
    error NotPendingBeneficiary();
    error ZeroAddress();
    error BadSchedule();
    error NothingToRelease();
    error NoProposal();
    error TooEarly(uint64 eta);
    error NotLonger();
    error VestingToken();

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    constructor(IERC20 token_, address beneficiary_, uint64 start_, uint64 cliff_, uint64 duration_, uint64 beneficiaryDelay_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (duration_ < MIN_DURATION) revert BadSchedule();
        token = token_;
        beneficiary = beneficiary_;
        start = start_;
        cliff = cliff_;
        duration = duration_;
        beneficiaryDelay = beneficiaryDelay_;
    }

    // ---------- the schedule ----------

    /// @notice Everything this vault has ever held for vesting: what it holds now plus what it already released.
    function totalAllocation() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    /// @notice How much has vested by `timestamp`, released or not.
    function vestedAmount(uint64 timestamp) public view returns (uint256) {
        uint64 unlockStart = start + cliff;
        if (timestamp < unlockStart) return 0;
        uint256 total = totalAllocation();
        uint64 elapsed = timestamp - unlockStart;
        if (elapsed >= duration) return total;
        return (total * elapsed) / duration;
    }

    /// @notice What the beneficiary can take right now.
    function releasable() public view returns (uint256) {
        uint256 vested = vestedAmount(uint64(block.timestamp));
        return vested > released ? vested - released : 0;
    }

    /// @notice Sends what has vested to the beneficiary. Anyone can call it; the tokens only ever go to the beneficiary.
    function release() external nonReentrant {
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        address to = beneficiary;
        token.safeTransfer(to, amount);
        emit Released(to, amount);
    }

    /// @notice Makes the vesting last longer. It can never be shortened.
    function extendDuration(uint64 newDuration) external onlyBeneficiary {
        if (newDuration <= duration) revert NotLonger();
        emit DurationExtended(duration, newDuration);
        duration = newDuration;
    }

    // ---------- changing the beneficiary: proposed, public, then delayed ----------

    function proposeBeneficiary(address proposed) external onlyBeneficiary {
        if (proposed == address(0)) revert ZeroAddress();
        pendingBeneficiary = proposed;
        pendingBeneficiaryEta = uint64(block.timestamp) + beneficiaryDelay;
        emit BeneficiaryProposed(beneficiary, proposed, pendingBeneficiaryEta);
    }

    function cancelBeneficiary() external onlyBeneficiary {
        address proposed = pendingBeneficiary;
        if (proposed == address(0)) revert NoProposal();
        delete pendingBeneficiary;
        delete pendingBeneficiaryEta;
        emit BeneficiaryCancelled(proposed);
    }

    /// @notice The proposed beneficiary takes over once the delay has passed.
    function acceptBeneficiary() external {
        address proposed = pendingBeneficiary;
        if (proposed == address(0)) revert NoProposal();
        if (msg.sender != proposed) revert NotPendingBeneficiary();
        if (block.timestamp < pendingBeneficiaryEta) revert TooEarly(pendingBeneficiaryEta);
        emit BeneficiaryChanged(beneficiary, proposed);
        beneficiary = proposed;
        delete pendingBeneficiary;
        delete pendingBeneficiaryEta;
    }

    // ---------- tokens sent here by mistake ----------

    /// @notice Returns any other token sent here by mistake to the beneficiary. The vesting token can never leave
    ///         through this path.
    function recover(IERC20 otherToken) external nonReentrant {
        if (address(otherToken) == address(token)) revert VestingToken();
        uint256 amount = otherToken.balanceOf(address(this));
        address to = beneficiary;
        otherToken.safeTransfer(to, amount);
        emit Recovered(address(otherToken), to, amount);
    }
}
