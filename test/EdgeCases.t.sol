// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract EdgeToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Refuses ETH until told otherwise.
contract Refuser {
    bool public open;

    function setOpen(bool o) external {
        open = o;
    }

    receive() external payable {
        require(open, "no");
    }
}

/// @notice Failure paths and exact boundaries the other suites leave out: every revert the vaults and the factory
///         declare, and the second either side of each delay.
contract EdgeCasesTest is Test {
    address radar = makeAddr("radar");
    address project = makeAddr("project");
    address team = makeAddr("team");
    address heir = makeAddr("heir");
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    EdgeToken imd;
    EdgeToken token;
    VaultFactory factory;

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = new EdgeToken("IMD");
        token = new EdgeToken("PROJ");
        factory = new VaultFactory(IERC20(address(imd)), radar);
        imd.mint(project, 100e18);
        token.mint(project, 1_000_000e18);
        vm.startPrank(project);
        imd.approve(address(factory), type(uint256).max);
        token.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function _vesting(uint256 amount, uint64 cliff, uint64 duration) internal returns (VestingVault v) {
        vm.prank(project);
        v = factory.createVesting(IERC20(address(token)), team, amount, uint64(block.timestamp), cliff, duration);
    }

    function _treasury(address[] memory dest) internal returns (TreasuryVault t) {
        vm.prank(project);
        t = factory.createTreasury(address(token), multisig, 1 days, 2_500, dest);
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    // =================== factory ===================

    function test_CreateVestingRejectsZeroAmountAndZeroBeneficiary() public {
        vm.startPrank(project);
        vm.expectRevert(VaultFactory.ZeroAmount.selector);
        factory.createVesting(IERC20(address(token)), team, 0, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        factory.createVesting(IERC20(address(token)), address(0), 1, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        factory.createLaunchVesting(address(0), uint64(block.timestamp), 0, 28 days);
        vm.stopPrank();
        assertEq(factory.vaultCount(), 0);
        assertEq(imd.balanceOf(radar), 0, "no fee for a vault that was never made");
        assertFalse(factory.feePaid(block.chainid, address(token)));
    }

    function test_DurationFloorIsExactlyFourWeeks() public {
        vm.startPrank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1e18, uint64(block.timestamp), 0, 28 days - 1);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days - 1);
        VestingVault v = factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        vm.stopPrank();
        assertEq(v.duration(), 28 days);
    }

    function test_FeeFailureLeavesNothingBehind() public {
        address poor = makeAddr("poor");
        token.mint(poor, 1e18);
        vm.startPrank(poor);
        token.approve(address(factory), type(uint256).max);
        // no IMD approved: the whole creation reverts, tokens stay put and nothing is registered
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 5e18)
        );
        factory.createVesting(IERC20(address(token)), team, 1e18, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert();
        factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert();
        factory.createTreasury(address(0), poor, 1 days, 2_500, new address[](0));
        vm.stopPrank();
        assertEq(token.balanceOf(poor), 1e18);
        assertEq(factory.vaultCount(), 0);
        assertFalse(factory.feePaid(block.chainid, address(token)));
    }

    function test_FeeIsChargedToTheCallerOnlyOnceEvenAcrossKinds() public {
        vm.startPrank(project);
        _vestingAsCaller();
        factory.createTreasury(address(token), multisig, 1 days, 2_500, new address[](0));
        factory.createVesting(IERC20(address(token)), heir, 1e18, uint64(block.timestamp), 0, 28 days);
        vm.stopPrank();
        assertEq(imd.balanceOf(radar), 5e18);
        assertEq(imd.balanceOf(project), 95e18);
        assertEq(factory.vaultsByToken(address(token)).length, 3);
    }

    function _vestingAsCaller() internal {
        factory.createVesting(IERC20(address(token)), team, 1e18, uint64(block.timestamp), 0, 28 days);
    }

    function test_PayForRejectsZeroTokenAndSecondPayment() public {
        vm.startPrank(project);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.payFor(4663, address(0));
        factory.payFor(4663, address(token));
        vm.expectRevert(VaultFactory.AlreadyPaid.selector);
        factory.payFor(4663, address(token));
        vm.stopPrank();
        // paying for one chain does not pay for another
        assertTrue(factory.feePaid(4663, address(token)));
        assertFalse(factory.feePaid(block.chainid, address(token)));
        assertEq(imd.balanceOf(radar), 5e18);
    }

    function test_PayForThisChainCoversTheFirstVault() public {
        vm.prank(stranger);
        vm.expectRevert(); // a stranger with no IMD can not pay
        factory.payFor(block.chainid, address(token));
        vm.prank(project);
        factory.payFor(block.chainid, address(token));
        uint256 before = imd.balanceOf(project);
        _vesting(1e18, 0, 28 days);
        assertEq(imd.balanceOf(project), before, "already paid, the first vault is free");
    }

    function test_CreateTreasuryRejectsBadArguments() public {
        vm.startPrank(project);
        vm.expectRevert(VaultFactory.BadDelay.selector);
        factory.createTreasury(address(token), multisig, 1 days - 1, 2_500, new address[](0));
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        factory.createTreasury(address(token), multisig, 30 days + 1, 2_500, new address[](0));
        vm.expectRevert(TreasuryVault.BadRate.selector);
        factory.createTreasury(address(token), multisig, 1 days, 0, new address[](0));
        vm.expectRevert(TreasuryVault.BadRate.selector);
        factory.createTreasury(address(token), multisig, 1 days, 2_501, new address[](0));
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        factory.createTreasury(address(token), address(0), 1 days, 2_500, new address[](0));
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        factory.createTreasury(address(token), multisig, 1 days, 2_500, _one(address(0)));
        // the bounds themselves are allowed
        TreasuryVault t = factory.createTreasury(address(token), multisig, 30 days, 1, new address[](0));
        vm.stopPrank();
        assertEq(t.delay(), 30 days);
        assertEq(t.rateBps(), 1);
        assertFalse(t.restricted());
    }

    function test_DuplicateDestinationsAreListedOnce() public {
        address[] memory l = new address[](3);
        l[0] = multisig;
        l[1] = multisig;
        l[2] = stranger;
        TreasuryVault t = _treasury(l);
        assertEq(t.destinations().length, 2);
        vm.startPrank(multisig);
        t.removeDestination(stranger);
        // the duplicate does not let the last one go
        vm.expectRevert(TreasuryVault.NotListed.selector);
        t.removeDestination(multisig);
        vm.stopPrank();
    }

    // =================== vesting: boundaries ===================

    function test_NothingAtTheCliffSecondThenLinear() public {
        VestingVault v = _vesting(28e18, 10 days, 28 days);
        uint64 from = v.start() + v.cliff();
        vm.warp(from);
        assertEq(v.releasable(address(token)), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
        vm.warp(from + 1 days);
        assertEq(v.releasable(address(token)), 1e18);
        vm.warp(from + 28 days - 1);
        assertLt(v.releasable(address(token)), 28e18);
        vm.warp(from + 28 days);
        assertEq(v.releasable(address(token)), 28e18);
    }

    function test_ReleaseTwiceInOneBlockPaysOnce() public {
        VestingVault v = _vesting(28e18, 0, 28 days);
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        v.release(address(token));
        assertEq(token.balanceOf(team), 7e18);
        assertEq(token.balanceOf(stranger), 0, "anyone calls, only the beneficiary is paid");
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
    }

    function test_SyncIsANoOpOnABoundVaultAndRefusesOtherAssets() public {
        VestingVault v = _vesting(1e18, 0, 28 days);
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), 0);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(imd)));
        v.sync(address(imd));
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        v.release(address(0));
        assertEq(v.releasable(address(imd)), 0);
    }

    function test_OpenVaultReleaseBeforeAnythingArrivesReverts() public {
        vm.prank(project);
        VestingVault v = factory.createLaunchVesting(team, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));
        assertEq(v.arrivedAt(address(token)), 0, "an empty token never starts its clock");
        assertEq(v.unlockStart(address(token)), 0);
    }

    function test_OnlyTheBeneficiaryChangesTheSchedule() public {
        VestingVault v = _vesting(1e18, 0, 28 days);
        vm.startPrank(stranger);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.extendDuration(29 days);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.cancelBeneficiary();
        vm.stopPrank();
        vm.prank(team);
        vm.expectRevert(VestingVault.ZeroAddress.selector);
        v.proposeBeneficiary(address(0));
        vm.prank(team);
        vm.expectRevert(VestingVault.NotLonger.selector);
        v.extendDuration(28 days);
    }

    function test_BeneficiaryHandoverAtTheExactSecondAndAfter() public {
        VestingVault v = _vesting(28e18, 0, 28 days);
        vm.prank(team);
        v.proposeBeneficiary(heir);
        uint64 eta = v.pendingBeneficiaryEta();
        assertEq(eta, block.timestamp + 7 days);

        vm.warp(eta - 1);
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.TooEarly.selector, eta));
        v.acceptBeneficiary();
        // a re-proposal restarts the delay
        vm.prank(team);
        v.proposeBeneficiary(heir);
        vm.warp(eta);
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.TooEarly.selector, eta - 1 + 7 days));
        v.acceptBeneficiary();

        vm.warp(eta - 1 + 7 days);
        vm.prank(heir);
        v.acceptBeneficiary();
        assertEq(v.beneficiary(), heir);
        assertEq(v.pendingBeneficiary(), address(0));

        // the old beneficiary has no power left, and payouts go to the new one
        vm.prank(team);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.extendDuration(60 days);
        vm.prank(heir);
        vm.expectRevert(VestingVault.NoProposal.selector);
        v.acceptBeneficiary();
        v.release(address(token));
        assertEq(token.balanceOf(team), 0);
        assertGt(token.balanceOf(heir), 0);
    }

    function testFuzz_ReleasedNeverExceedsDeposited(uint96 amount, uint32[6] memory gaps, uint32 extra) public {
        uint256 amt = bound(amount, 1, 1_000_000e18);
        VestingVault v = _vesting(amt, 3 days, 28 days);
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(block.timestamp + bound(gaps[i], 0, 15 days));
            if (i == 2) {
                vm.prank(team);
                try v.extendDuration(v.duration() + uint64(bound(extra, 1, 365 days))) {} catch {}
            }
            try v.release(address(token)) {} catch {}
            assertEq(token.balanceOf(team), v.released(address(token)));
            assertLe(v.releasable(address(token)), token.balanceOf(address(v)));
            assertEq(token.balanceOf(team) + token.balanceOf(address(v)), amt);
        }
    }

    // =================== treasury: failure paths and boundaries ===================

    function test_TreasuryDepositAndQueueRejectZero() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.prank(project);
        vm.expectRevert(TreasuryVault.ZeroAmount.selector);
        t.deposit(IERC20(address(token)), 0);
        vm.startPrank(multisig);
        vm.expectRevert(TreasuryVault.ZeroAmount.selector);
        t.queue(address(token), multisig, 0);
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        t.queue(address(token), address(0), 1);
        vm.stopPrank();
    }

    function test_TreasuryUnknownIdsRevert() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.expectRevert(TreasuryVault.UnknownWithdrawal.selector);
        t.execute(0);
        vm.prank(multisig);
        vm.expectRevert(TreasuryVault.UnknownWithdrawal.selector);
        t.cancel(0);
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.cancel(0);
    }

    function test_TreasuryDelayAndGraceBoundaries() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 1000e18);
        vm.startPrank(multisig);
        uint256 a = t.queue(address(token), multisig, 1e18);
        uint256 b = t.queue(address(token), multisig, 1e18);
        vm.stopPrank();
        uint64 due = uint64(block.timestamp) + 1 days;

        vm.warp(due - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, due));
        t.execute(a);
        vm.warp(due);
        t.execute(a);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(a);

        vm.warp(due + 14 days + 1);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(b);
        // an expired withdrawal can still be cancelled, and then never runs
        vm.prank(multisig);
        t.cancel(b);
        vm.prank(multisig);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.cancel(b);
        assertEq(token.balanceOf(multisig), 1e18);
    }

    function test_TreasuryLastSecondOfGraceExecutes() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 1000e18);
        vm.prank(multisig);
        uint256 id = t.queue(address(token), multisig, 1e18);
        vm.warp(block.timestamp + 1 days + 14 days);
        t.execute(id);
        assertEq(token.balanceOf(multisig), 1e18);
    }

    function test_TreasuryCapExactlyAvailableThenOneWeiOver() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 1000e18);
        vm.startPrank(multisig);
        uint256 a = t.queue(address(token), multisig, 250e18);
        uint256 b = t.queue(address(token), multisig, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(t.availableThisWeek(address(token)), 250e18);
        t.execute(a);
        assertEq(t.availableThisWeek(address(token)), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
        // next epoch: a fresh cap on the new balance
        vm.warp((block.timestamp / 7 days + 1) * 7 days);
        assertEq(t.availableThisWeek(address(token)), 750e18 / 4);
        t.execute(b);
    }

    function test_TreasuryEthToARefusingDestinationRollsBackAndCanRetry() public {
        Refuser r = new Refuser();
        TreasuryVault t = _treasury(_one(address(r)));
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(t).call{value: 10 ether}("");
        assertTrue(ok);
        vm.prank(multisig);
        uint256 id = t.queue(address(0), address(r), 1 ether);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(TreasuryVault.EthTransferFailed.selector);
        t.execute(id);
        (,,,,, bool done) = t.withdrawals(id);
        assertFalse(done);
        assertEq(t.availableThisWeek(address(0)), 2.5 ether, "the failed call spent no cap");
        r.setOpen(true);
        t.execute(id);
        assertEq(address(r).balance, 1 ether);
        assertEq(address(t).balance, 9 ether);
    }

    function test_TreasuryDestinationRulesFailurePaths() public {
        TreasuryVault open = _treasury(new address[](0));
        vm.startPrank(multisig);
        vm.expectRevert(TreasuryVault.NotRestricted.selector);
        open.removeDestination(multisig);
        vm.expectRevert(TreasuryVault.NotListed.selector);
        open.restrictDestinations(new address[](0));
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        open.restrictDestinations(_one(address(0)));
        assertFalse(open.restricted(), "a refused restriction leaves the vault as it was");
        open.restrictDestinations(_one(multisig));
        vm.expectRevert(TreasuryVault.NotListed.selector);
        open.removeDestination(stranger);
        vm.expectRevert(TreasuryVault.NotListed.selector);
        open.removeDestination(multisig);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        open.restrictDestinations(_one(stranger));
    }

    function test_TreasuryRuleBoundsAtTheEdges() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.startPrank(multisig);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        t.increaseDelay(1 days);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        t.increaseDelay(30 days + 1);
        t.increaseDelay(30 days);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        t.increaseDelay(30 days);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        t.decreaseRate(2_500);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        t.decreaseRate(0);
        t.decreaseRate(1);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        t.decreaseRate(1);
        vm.stopPrank();
        vm.startPrank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.increaseDelay(2 days);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.decreaseRate(1);
        vm.stopPrank();
    }

    function test_TreasuryManagerHandoverFailurePaths() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.proposeManager(stranger);
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NoProposal.selector);
        t.acceptManager();
        vm.startPrank(multisig);
        vm.expectRevert(TreasuryVault.ZeroAddress.selector);
        t.proposeManager(address(0));
        vm.expectRevert(TreasuryVault.NoProposal.selector);
        t.cancelManager();
        t.proposeManager(heir);
        vm.stopPrank();
        uint64 eta = t.pendingManagerEta();
        assertEq(eta, block.timestamp + 1 days);
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotPendingManager.selector);
        t.acceptManager();
        vm.warp(eta - 1);
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, eta));
        t.acceptManager();
        vm.warp(eta);
        vm.prank(heir);
        t.acceptManager();
        assertEq(t.manager(), heir);
        vm.prank(multisig);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(address(token), multisig, 1);
    }

    function test_CancelledProposalCanNotBeAccepted() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.prank(multisig);
        t.proposeManager(heir);
        vm.prank(multisig);
        t.cancelManager();
        vm.warp(block.timestamp + 2 days);
        vm.prank(heir);
        vm.expectRevert(TreasuryVault.NoProposal.selector);
        t.acceptManager();
        assertEq(t.manager(), multisig);
    }
}
