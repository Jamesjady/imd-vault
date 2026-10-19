// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract AuditToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token with two entry points to one balance, like TrueUSD's legacy contract: `legacy` forwards transfers
///      into the main token on behalf of its caller.
contract DoubleEntryToken is AuditToken {
    address public legacy;

    constructor() AuditToken("DBL") {}

    function setLegacy(address legacy_) external {
        legacy = legacy_;
    }

    function transferFor(address from, address to, uint256 amount) external {
        require(msg.sender == legacy, "not legacy");
        _transfer(from, to, amount);
    }
}

contract LegacyEntry {
    DoubleEntryToken immutable main;

    constructor(DoubleEntryToken main_) {
        main = main_;
    }

    function balanceOf(address a) external view returns (uint256) {
        return main.balanceOf(a);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        main.transferFor(msg.sender, to, amount);
        return true;
    }
}

/// @notice One test per audit finding fixed in ADAPTATION.md. Each reproduced on the code as it arrived.
contract AuditTest is Test {
    address radar = makeAddr("radar");
    address project = makeAddr("project");
    address team = makeAddr("team");
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    AuditToken imd;
    AuditToken token;
    VaultFactory factory;

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = new AuditToken("IMD");
        token = new AuditToken("PROJ");
        factory = new VaultFactory(IERC20(address(imd)), radar);
        imd.mint(project, 1000e18);
        token.mint(project, 10_000_000e18);
        vm.startPrank(project);
        imd.approve(address(factory), type(uint256).max);
        token.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function _open(uint64 start, uint64 cliff, uint64 duration) internal returns (VestingVault v) {
        vm.prank(project);
        v = factory.createLaunchVesting(team, start, cliff, duration);
    }

    // =================== 55055564: a start in the past unlocked everything at creation ===================

    function test_VestingRejectsStartInThePast() public {
        uint64 now_ = uint64(block.timestamp);
        vm.startPrank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_ - 28 days, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_ - 1, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createLaunchVesting(team, now_ - 1, 0, 28 days);
        // Now and later are fine, and nothing is moved by the refused calls.
        VestingVault v = factory.createVesting(IERC20(address(token)), team, 1_000_000e18, now_, 0, 28 days);
        factory.createLaunchVesting(team, now_ + 30 days, 0, 28 days);
        vm.stopPrank();
        assertEq(token.balanceOf(project), 9_000_000e18);
        assertEq(v.releasable(address(token)), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 250_000e18);
    }

    /// @dev The audit's proof, kept as a regression: whatever the start, at most 25% leaves in the first week.
    function testFuzz_VestingNeverMoreThan25PercentInFirstWeek(uint64 start, uint64 cliff, uint64 duration) public {
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        start = uint64(bound(start, 0, block.timestamp + 365 days));
        vm.prank(project);
        try factory.createVesting(IERC20(address(token)), team, 1_000_000e18, start, cliff, duration) returns (
            VestingVault v
        ) {
            assertGe(start, block.timestamp);
            vm.warp(block.timestamp + 7 days);
            assertLe(v.releasable(address(token)), 250_000e18 + 1);
        } catch (bytes memory err) {
            assertEq(bytes4(err), VestingVault.BadSchedule.selector);
            assertLt(start, block.timestamp);
        }
    }

    // =================== 5dbb3b32: tokens that reach an open vault late unlocked on arrival ===================

    function test_LateArrivalVestsFromArrival() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.warp(block.timestamp + 28 days); // the launch slips past the whole schedule
        token.mint(address(v), 1_000_000e18);

        // Nothing vests until the arrival is recorded, and nothing on the arrival itself.
        assertEq(v.unlockStart(address(token)), 0);
        assertEq(v.releasable(address(token)), 0);
        vm.prank(stranger);
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), uint64(block.timestamp));
        assertEq(v.unlockStart(address(token)), uint64(block.timestamp));
        assertEq(v.releasable(address(token)), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release(address(token));

        // Then the chosen schedule, from the arrival: 25% a week over four weeks.
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 250_000e18);
        v.release(address(token));
        assertEq(token.balanceOf(team), 250_000e18);
        vm.warp(block.timestamp + 21 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 1_000_000e18);
    }

    function test_ArrivalInsideTheCliffKeepsTheSchedule() public {
        uint64 start = uint64(block.timestamp);
        VestingVault v = _open(start, 14 days, 28 days);
        vm.warp(block.timestamp + 3 days); // the launch is a little late but still inside the cliff
        token.mint(address(v), 1000e18);
        v.sync(address(token));
        assertEq(v.unlockStart(address(token)), start + 14 days);
        vm.warp(start + 14 days);
        assertEq(v.releasable(address(token)), 0);
        vm.warp(start + 21 days);
        assertEq(v.releasable(address(token)), 250e18);
    }

    function test_FirstReleaseOfANewTokenOnlyStartsItsClock() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.warp(block.timestamp + 10 days);
        token.mint(address(v), 1000e18);
        vm.expectEmit(true, false, false, true, address(v));
        emit VestingVault.Arrived(address(token), uint64(block.timestamp));
        v.release(address(token)); // records the arrival, pays nothing, and keeps the record (no revert)
        assertEq(token.balanceOf(team), 0);
        assertEq(v.arrivedAt(address(token)), uint64(block.timestamp));
        vm.warp(block.timestamp + 7 days);
        v.release(address(token));
        assertEq(token.balanceOf(team), 250e18);
    }

    function test_SyncIsIdempotentAndNeedsABalance() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        v.sync(address(token)); // holds none yet: nothing recorded
        assertEq(v.arrivedAt(address(token)), 0);
        token.mint(address(v), 1e18);
        v.sync(address(token));
        uint64 first = v.arrivedAt(address(token));
        vm.warp(block.timestamp + 5 days);
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), first); // a second call never moves the clock
        vm.expectRevert(abi.encodeWithSelector(VestingVault.NotVested.selector, address(0)));
        v.sync(address(0));
    }

    function test_EachTokenInAnOpenVaultHasItsOwnClock() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        token.mint(address(v), 1000e18);
        v.sync(address(token));
        vm.warp(block.timestamp + 14 days);
        imd.mint(address(v), 100e18);
        v.sync(address(imd));
        assertEq(v.releasable(address(token)), 500e18);
        assertEq(v.releasable(address(imd)), 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(v.releasable(address(token)), 750e18);
        assertEq(v.releasable(address(imd)), 25e18);
    }

    function test_BoundVaultHasNoArrivalClock() public {
        vm.prank(project);
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 100 days);
        assertEq(v.unlockStart(address(token)), uint64(block.timestamp));
        v.sync(address(token));
        assertEq(v.arrivedAt(address(token)), 0);
        vm.warp(block.timestamp + 50 days);
        vm.prank(project);
        token.transfer(address(v), 1000e18); // a top-up still follows the calendar schedule, as the README says
        assertEq(v.releasable(address(token)), 1000e18);
    }

    function testFuzz_LateArrivalNeverUnlocksMoreThan25PercentInAWeek(
        uint256 amount,
        uint64 cliff,
        uint64 duration,
        uint64 slip,
        uint64 at
    ) public {
        amount = bound(amount, 1e6, 1_000_000e18);
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        slip = uint64(bound(slip, 0, 2 * 365 days));
        VestingVault v = _open(uint64(block.timestamp), cliff, duration);
        vm.warp(block.timestamp + slip);
        token.mint(address(v), amount);
        v.sync(address(token));
        assertEq(v.releasable(address(token)), 0, "unlocked on arrival");
        uint64 t = uint64(bound(at, block.timestamp, block.timestamp + cliff + duration));
        uint256 week = v.vestedAmount(address(token), t + 7 days) - v.vestedAmount(address(token), t);
        assertLe(week, amount / 4 + 1);
    }

    // =================== 9267dfb4: the real bound of the fixed-epoch weekly cap, now documented ===================

    function test_TreasuryEpochBoundaryBoundIsRatePlusRateOfRemainder() public {
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
        token.mint(address(t), 10_000e18);
        vm.startPrank(project);
        uint256 a = t.queue(address(token), multisig, 2_500e18);
        uint256 b = t.queue(address(token), multisig, 1_875e18);
        uint256 c = t.queue(address(token), multisig, 1);
        vm.stopPrank();
        uint256 boundary = ((block.timestamp + 1 days) / t.EPOCH() + 1) * t.EPOCH();
        vm.warp(boundary - 1);
        t.execute(a);
        vm.warp(boundary);
        t.execute(b);
        // 25% + 25% of the remaining 75% = 43.75% across the boundary, and not a wei more this week.
        assertEq(token.balanceOf(multisig), 4_375e18);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(c);
    }

    // =================== ea7dc628: an overflowing schedule trapped the tokens forever ===================

    function test_VestingRejectsOverflowingSchedule() public {
        vm.startPrank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max, 1, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max - 28 days + 1, 0, 28 days);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createLaunchVesting(team, type(uint64).max - 10 days, 0, 28 days);
        // The largest schedule that fits is accepted, and no tokens moved for the refused ones.
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, type(uint64).max - 28 days, 0, 28 days);
        vm.stopPrank();
        assertEq(token.balanceOf(project), 10_000_000e18 - 1000e18);
        assertEq(v.releasable(address(token)), 0);
        assertEq(v.vestedAmount(address(token), type(uint64).max), 1000e18);
    }

    function test_ExtendDurationCannotOverflowTheSchedule() public {
        vm.prank(project);
        VestingVault v =
            factory.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        vm.prank(team);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        v.extendDuration(type(uint64).max);
        vm.prank(team);
        v.extendDuration(365 days);
        assertEq(v.duration(), 365 days);
    }

    // =================== 5f526bd2: recover() moved the vested token through a second entry point ===================

    function test_RecoverRefusesASecondEntryPointToTheVestedToken() public {
        DoubleEntryToken dbl = new DoubleEntryToken();
        LegacyEntry legacy = new LegacyEntry(dbl);
        dbl.setLegacy(address(legacy));
        dbl.mint(project, 1000e18);
        vm.startPrank(project);
        dbl.approve(address(factory), type(uint256).max);
        VestingVault v =
            factory.createVesting(IERC20(address(dbl)), team, 1000e18, uint64(block.timestamp), 365 days, 28 days);
        vm.stopPrank();

        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(legacy)));
        assertEq(dbl.balanceOf(address(v)), 1000e18);
        assertEq(dbl.balanceOf(team), 0);

        // A genuinely different token still comes back to the beneficiary.
        imd.mint(address(v), 5e18);
        v.recover(IERC20(address(imd)));
        assertEq(imd.balanceOf(team), 5e18);
    }

    function test_OpenVaultRecoverAlwaysRefuses() public {
        VestingVault v = _open(uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(0)));
        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(imd)));
    }

    // =================== 6a087594: the 24h floor is now in the treasury itself ===================

    function test_TreasuryConstructorEnforcesMinDelay() public {
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        new TreasuryVault(address(token), project, 0, 2500, new address[](0));
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        new TreasuryVault(address(token), project, 1 days - 1, 2500, new address[](0));
        TreasuryVault t = new TreasuryVault(address(token), project, 1 days, 2500, new address[](0));
        assertEq(t.delay(), 1 days);
        assertEq(t.MIN_DELAY(), factory.MIN_DELAY());
    }
}
