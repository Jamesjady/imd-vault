// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns 1% of every transfer, to check that vaults account by balance.
contract FeeToken is MockToken {
    constructor() MockToken("FEE") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract VaultTest is Test {
    address radar = makeAddr("radar");

    MockToken imd;
    MockToken token;
    VaultFactory factory;

    address project = makeAddr("project");
    address team = makeAddr("team");
    address multisig = makeAddr("multisig");
    address intake = makeAddr("intake");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = new MockToken("IMD");
        token = new MockToken("PROJ");
        factory = new VaultFactory(IERC20(address(imd)), radar);
        imd.mint(project, 100e18);
        token.mint(project, 1_000_000e18);
        vm.startPrank(project);
        imd.approve(address(factory), type(uint256).max);
        token.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    // =================== factory ===================

    function _vesting(uint256 amount, uint64 cliff, uint64 duration) internal returns (VestingVault) {
        vm.prank(project);
        return factory.createVesting(IERC20(address(token)), team, amount, uint64(block.timestamp), cliff, duration);
    }

    function _treasury(address[] memory dest) internal returns (TreasuryVault) {
        vm.prank(project);
        return factory.createTreasury(address(token), project, 2 days, 1000, dest);
    }

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function test_FactoryBurnsFeeOncePerProjectAndRegisters() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        TreasuryVault t = _treasury(new address[](0)); // same token: no second fee
        assertEq(imd.balanceOf(radar), 5e18);
        assertEq(imd.balanceOf(project), 95e18);
        assertTrue(factory.feePaid(block.chainid, address(token)));
        assertEq(token.balanceOf(address(v)), 1000e18);
        assertTrue(factory.isVault(address(v)));
        assertTrue(factory.isVault(address(t)));
        assertEq(factory.vaultCount(), 2);
        address[] memory byToken = factory.vaultsByToken(address(token));
        assertEq(byToken.length, 2);
        assertEq(byToken[0], address(v));
        assertEq(byToken[1], address(t));
    }

    function test_FactoryChargesEachNewProject() public {
        _vesting(1000e18, 0, 100 days);
        MockToken other = new MockToken("OTHER");
        vm.prank(project);
        factory.createTreasury(address(other), project, 2 days, 1000, new address[](0));
        assertEq(imd.balanceOf(radar), 10e18);
    }

    function test_FeeGoesToRadarNotBurned() public {
        _vesting(1000e18, 0, 100 days);
        assertEq(imd.balanceOf(radar), 5e18);
        assertEq(imd.totalSupply(), 100e18); // nothing burned
    }

    function test_PayForRobinhoodProject() public {
        address rhToken = makeAddr("rhToken");
        vm.prank(project);
        factory.payFor(4663, rhToken);
        assertTrue(factory.feePaid(4663, rhToken));
        assertFalse(factory.feePaid(block.chainid, rhToken));
        assertEq(imd.balanceOf(radar), 5e18);
        vm.prank(project);
        vm.expectRevert(VaultFactory.AlreadyPaid.selector);
        factory.payFor(4663, rhToken);
    }

    function test_FreeFactoryOnChainsWithoutImd() public {
        VaultFactory rh = new VaultFactory(IERC20(address(0)), address(0));
        token.mint(stranger, 1000e18);
        vm.startPrank(stranger); // holds no IMD and approves none
        token.approve(address(rh), type(uint256).max);
        VestingVault v = rh.createVesting(IERC20(address(token)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        vm.expectRevert(VaultFactory.NoFeeOnThisChain.selector);
        rh.payFor(1, address(token));
        vm.stopPrank();
        assertTrue(rh.isVault(address(v)));
        assertFalse(rh.feePaid(block.chainid, address(token)));
    }

    function test_FactoryNeedsRadarWalletWhenCharging() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(IERC20(address(imd)), address(0));
    }

    function test_TreasuryRateCappedAt25Percent() public {
        vm.prank(project);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        factory.createTreasury(address(token), project, 1 days, 2501, new address[](0));
        vm.prank(project);
        factory.createTreasury(address(token), project, 1 days, 2500, new address[](0));
    }

    function test_FactoryRevertsWithoutImd() public {
        vm.startPrank(stranger);
        token.approve(address(factory), type(uint256).max);
        vm.expectRevert();
        factory.createTreasury(address(token), stranger, 2 days, 1000, new address[](0));
        vm.stopPrank();
    }

    function test_FactoryRejectsShortDelay() public {
        vm.prank(project);
        vm.expectRevert(VaultFactory.BadDelay.selector);
        factory.createTreasury(address(token), project, 1 hours, 1000, new address[](0));
    }

    // =================== vesting ===================

    function test_VestingCliffThenLinear() public {
        VestingVault v = _vesting(1200e18, 30 days, 120 days);
        assertEq(v.releasable(), 0);
        vm.expectRevert(VestingVault.NothingToRelease.selector);
        v.release();

        vm.warp(block.timestamp + 30 days); // cliff over: the linear unlock starts here, nothing jumps
        assertEq(v.releasable(), 0);

        vm.warp(block.timestamp + 30 days);
        assertEq(v.releasable(), 300e18);

        vm.prank(stranger); // anyone can release, the beneficiary gets paid
        v.release();
        assertEq(token.balanceOf(team), 300e18);

        vm.warp(block.timestamp + 30 days);
        v.release();
        assertEq(token.balanceOf(team), 600e18);

        vm.warp(block.timestamp + 365 days);
        v.release();
        assertEq(token.balanceOf(team), 1200e18);
        assertEq(token.balanceOf(address(v)), 0);
    }

    function test_VestingTopUpFollowsSchedule() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        vm.warp(block.timestamp + 50 days);
        vm.prank(project);
        token.transfer(address(v), 1000e18);
        assertEq(v.releasable(), 1000e18); // half of 2000
    }

    function test_VestingFeeOnTransferToken() public {
        FeeToken ft = new FeeToken();
        ft.mint(project, 1000e18);
        vm.startPrank(project);
        ft.approve(address(factory), type(uint256).max);
        VestingVault v = factory.createVesting(IERC20(address(ft)), team, 1000e18, uint64(block.timestamp), 0, 28 days);
        vm.stopPrank();
        assertEq(v.totalAllocation(), 990e18);
        vm.warp(block.timestamp + 28 days);
        v.release(); // must not revert even though the vault receives less than it was told
        assertEq(ft.balanceOf(address(v)), 0);
    }

    function test_VestingOnlyExtends() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        vm.prank(team);
        vm.expectRevert(VestingVault.NotLonger.selector);
        v.extendDuration(50 days);
        vm.prank(stranger);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.extendDuration(200 days);
        vm.prank(team);
        v.extendDuration(200 days);
        vm.warp(block.timestamp + 100 days);
        assertEq(v.releasable(), 500e18);
    }

    function test_VestingExtendAfterReleaseNeverUnderflows() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        vm.warp(block.timestamp + 80 days);
        v.release();
        vm.prank(team);
        v.extendDuration(400 days); // vested now falls below what was released
        assertEq(v.releasable(), 0);
    }

    function test_VestingBeneficiaryChangeIsDelayed() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        address next = makeAddr("next");
        vm.prank(team);
        v.proposeBeneficiary(next);

        vm.prank(stranger);
        vm.expectRevert(VestingVault.NotPendingBeneficiary.selector);
        v.acceptBeneficiary();

        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(VestingVault.TooEarly.selector, uint64(block.timestamp + 7 days)));
        v.acceptBeneficiary();

        vm.warp(block.timestamp + 7 days);
        vm.prank(next);
        v.acceptBeneficiary();
        assertEq(v.beneficiary(), next);
        v.release();
        assertEq(token.balanceOf(next), 70e18);
    }

    function test_VestingBeneficiaryCancel() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        address next = makeAddr("next");
        vm.startPrank(team);
        v.proposeBeneficiary(next);
        v.cancelBeneficiary();
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(next);
        vm.expectRevert(VestingVault.NoProposal.selector);
        v.acceptBeneficiary();
    }

    function test_VestingRecoverOtherTokensOnly() public {
        VestingVault v = _vesting(1000e18, 0, 100 days);
        vm.expectRevert(VestingVault.VestingToken.selector);
        v.recover(IERC20(address(token)));
        imd.mint(address(v), 5e18);
        v.recover(IERC20(address(imd)));
        assertEq(imd.balanceOf(team), 5e18);
    }

    function test_VestingRejectsFasterThan25PercentAWeek() public {
        vm.prank(project);
        vm.expectRevert(VestingVault.BadSchedule.selector);
        factory.createVesting(IERC20(address(token)), team, 1e18, uint64(block.timestamp), 0, 28 days - 1);
        vm.prank(project);
        factory.createVesting(IERC20(address(token)), team, 1e18, uint64(block.timestamp), 0, 28 days);
    }

    function testFuzz_VestingNeverUnlocksMoreThan25PercentInAWeek(uint256 amount, uint64 cliff, uint64 duration, uint64 at)
        public
    {
        amount = bound(amount, 1e6, 1_000_000e18);
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        VestingVault v = _vesting(amount, cliff, duration);
        uint64 t = uint64(bound(at, block.timestamp, block.timestamp + cliff + duration));
        uint256 week = v.vestedAmount(t + 7 days) - v.vestedAmount(t);
        assertLe(week, amount / 4 + 1);
    }

    function testFuzz_VestingNeverOverpays(uint256 amount, uint64 cliff, uint64 duration, uint32[4] memory steps) public {
        amount = bound(amount, 1, 1_000_000e18);
        duration = uint64(bound(duration, 28 days, 4 * 365 days));
        cliff = uint64(bound(cliff, 0, 365 days));
        VestingVault v = _vesting(amount, cliff, duration);
        uint256 last;
        for (uint256 i; i < steps.length; ++i) {
            vm.warp(block.timestamp + steps[i]);
            uint256 vested = v.vestedAmount(uint64(block.timestamp));
            assertGe(vested, last);
            last = vested;
            if (v.releasable() > 0) v.release();
            assertLe(token.balanceOf(team), amount);
        }
        vm.warp(block.timestamp + cliff + duration);
        if (v.releasable() > 0) v.release();
        assertEq(token.balanceOf(team), amount);
    }

    // =================== treasury ===================

    function test_TreasuryDelayAndAnyoneExecutes() public {
        TreasuryVault t = _treasury(_list(multisig));
        token.mint(address(t), 10_000e18);

        vm.prank(project);
        uint256 id = t.queue(address(token), multisig, 500e18);

        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, uint64(block.timestamp + 2 days)));
        t.execute(id);

        vm.warp(block.timestamp + 2 days);
        vm.prank(stranger);
        t.execute(id);
        assertEq(token.balanceOf(multisig), 500e18);

        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(id);
    }

    function test_TreasuryOnlyManagerQueues() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(address(token), stranger, 1);
    }

    function test_TreasuryDestinationAllowlist() public {
        TreasuryVault t = _treasury(_list(multisig));
        vm.prank(project);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.NotAllowed.selector, stranger));
        t.queue(address(token), stranger, 1e18);
    }

    function test_TreasuryWeeklyCap() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 10_000e18); // cap: 10% = 1000 per week

        vm.startPrank(project);
        uint256 a = t.queue(address(token), multisig, 600e18);
        uint256 b = t.queue(address(token), multisig, 600e18);
        vm.stopPrank();

        // land in the middle of an epoch so both executions share it
        uint256 epoch = t.EPOCH();
        vm.warp(((block.timestamp + 2 days) / epoch + 1) * epoch + 1 hours);
        t.execute(a);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 400e18));
        t.execute(b);
        assertEq(t.availableThisWeek(address(token)), 400e18);

        // next epoch: the cap is 10% of the new balance (9400)
        vm.warp(block.timestamp + epoch);
        t.execute(b);
        assertEq(token.balanceOf(multisig), 1200e18);
    }

    function test_TreasuryCapIgnoresDepositsWithinEpoch() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 1000e18);
        vm.startPrank(project);
        uint256 a = t.queue(address(token), multisig, 100e18);
        uint256 b = t.queue(address(token), multisig, 100e18);
        vm.stopPrank();
        uint256 epoch = t.EPOCH();
        vm.warp(((block.timestamp + 2 days) / epoch + 1) * epoch + 1 hours);
        t.execute(a);
        token.mint(address(t), 1_000_000e18); // a big deposit does not raise this week's cap
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
    }

    function test_TreasuryEth() public {
        TreasuryVault t = _treasury(_list(multisig));
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        (bool ok,) = address(t).call{value: 10 ether}("");
        assertTrue(ok);

        vm.prank(project);
        uint256 id = t.queue(address(0), multisig, 1 ether);
        vm.warp(block.timestamp + 2 days);
        t.execute(id);
        assertEq(multisig.balance, 1 ether);
        assertEq(address(t).balance, 9 ether);
    }

    function test_TreasuryCancelAndExpiry() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 10_000e18);
        vm.startPrank(project);
        uint256 a = t.queue(address(token), multisig, 1e18);
        uint256 b = t.queue(address(token), multisig, 1e18);
        t.cancel(a);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(a);
        vm.warp(block.timestamp + 14 days + 1);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(b);
    }

    function test_TreasuryRulesOnlyTighten() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.startPrank(project);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        t.increaseDelay(1 days);
        vm.expectRevert(TreasuryVault.BadDelay.selector);
        t.increaseDelay(31 days);
        t.increaseDelay(7 days);
        assertEq(t.delay(), 7 days);

        vm.expectRevert(TreasuryVault.BadRate.selector);
        t.decreaseRate(2000);
        vm.expectRevert(TreasuryVault.BadRate.selector);
        t.decreaseRate(0);
        t.decreaseRate(500);
        assertEq(t.rateBps(), 500);

        address[] memory list = new address[](2);
        list[0] = multisig;
        list[1] = intake;
        t.restrictDestinations(list);
        vm.expectRevert(TreasuryVault.AlreadyRestricted.selector);
        t.restrictDestinations(_list(stranger));

        t.removeDestination(multisig);
        vm.expectRevert(TreasuryVault.NotListed.selector);
        t.removeDestination(intake); // the last destination stays
        vm.stopPrank();
        assertEq(t.destinations().length, 1);
        assertEq(t.destinations()[0], intake);
    }

    function test_TreasuryTighteningHoldsQueued() public {
        TreasuryVault t = _treasury(new address[](0));
        token.mint(address(t), 10_000e18);
        vm.startPrank(project);
        uint256 id = t.queue(address(token), multisig, 1e18);
        t.increaseDelay(5 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        t.execute(id);
        vm.warp(block.timestamp + 3 days);
        t.execute(id);

        vm.startPrank(project);
        uint256 id2 = t.queue(address(token), stranger, 1e18);
        t.restrictDestinations(_list(multisig));
        vm.stopPrank();
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.NotAllowed.selector, stranger));
        t.execute(id2);
    }

    function test_TreasuryManagerChangeIsDelayed() public {
        TreasuryVault t = _treasury(new address[](0));
        vm.prank(project);
        t.proposeManager(multisig);
        vm.prank(multisig);
        vm.expectRevert();
        t.acceptManager();
        vm.warp(block.timestamp + 2 days);
        vm.prank(multisig);
        t.acceptManager();
        assertEq(t.manager(), multisig);
        vm.prank(project);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(address(token), multisig, 1);
    }

    function testFuzz_TreasuryNeverExceedsWeeklyCap(uint256 balance, uint16 rate, uint256[5] memory amounts) public {
        balance = bound(balance, 1e18, 1e30);
        rate = uint16(bound(rate, 1, 2_500));
        vm.prank(project);
        TreasuryVault t = factory.createTreasury(address(token), project, 1 days, rate, new address[](0));
        token.mint(address(t), balance);

        uint256 epoch = t.EPOCH();
        uint256[5] memory ids;
        vm.startPrank(project);
        for (uint256 i; i < 5; ++i) ids[i] = t.queue(address(token), multisig, bound(amounts[i], 1, balance));
        vm.stopPrank();
        vm.warp(((block.timestamp + 1 days) / epoch + 1) * epoch + 1 hours);

        for (uint256 i; i < 5; ++i) {
            try t.execute(ids[i]) {} catch {}
        }
        assertLe(token.balanceOf(multisig), (balance * rate) / 10_000);
    }
}
