// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract ShToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev One balance behind two addresses: `legacy` forwards transfers into this token on behalf of its caller.
contract ShMain is ShToken {
    address public legacy;

    constructor() ShToken("MAIN") {}

    function setLegacy(address l) external {
        legacy = l;
    }

    function transferFor(address from, address to, uint256 amount) external {
        require(msg.sender == legacy, "not legacy");
        _transfer(from, to, amount);
    }
}

contract ShLegacy {
    ShMain immutable main;

    constructor(ShMain m) {
        main = m;
    }

    function balanceOf(address a) external view returns (uint256) {
        return main.balanceOf(a);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        main.transferFor(msg.sender, to, amount);
        return true;
    }
}

/// @dev Its `balanceOf` reverts while `broken` is set: a tracked asset that can not be read.
contract ShBroken is ShToken {
    bool public broken;

    constructor() ShToken("BRK") {}

    function setBroken(bool b) external {
        broken = b;
    }

    function balanceOf(address a) public view override returns (uint256) {
        require(!broken, "broken");
        return super.balanceOf(a);
    }
}

/// @dev Drives one open treasury holding a two-address token and an unrelated token: deposits, queues through either
///      address, executions by anyone, cancels, rate and delay tightening, and warps. Ghosts follow the shared balance.
contract SharedCapHandler is Test {
    TreasuryVault public t;
    ShMain public main;
    ShLegacy public legacy;
    ShToken public other;
    address public dest = makeAddr("dest");
    address public manager;

    uint256 public depositedShared;
    uint256 public withdrawnShared;
    uint256 public depositedOther;
    uint256 public withdrawnOther;

    // per epoch: shared balance before its first outflow, rate then, and everything that left the shared balance
    uint256 public gEpoch = type(uint256).max;
    uint256 public gStartBal;
    uint256 public gRate;
    uint256 public gSpent;
    mapping(uint256 => uint256) public gExpiry;

    bool public violated;
    string public why;
    uint256 public executions;
    uint256 public refusedOverCap;

    constructor(TreasuryVault t_, ShMain main_, ShLegacy legacy_, ShToken other_, address manager_) {
        t = t_;
        main = main_;
        legacy = legacy_;
        other = other_;
        manager = manager_;
    }

    function _asset(uint256 i) internal view returns (address) {
        uint256 k = i % 3;
        return k == 0 ? address(main) : k == 1 ? address(legacy) : address(other);
    }

    function _bad(string memory r) internal {
        violated = true;
        why = r;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 9 days));
    }

    function deposit(bool shared, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        if (shared) {
            main.mint(address(t), amount);
            depositedShared += amount;
        } else {
            other.mint(address(t), amount);
            depositedOther += amount;
        }
    }

    function queue(uint256 ai, uint256 amount) external {
        address asset = _asset(ai);
        uint256 bal = asset == address(other) ? other.balanceOf(address(t)) : main.balanceOf(address(t));
        // mostly amounts near the cap, so both sides of it are reached
        amount = bound(amount, 1, bal / 4 + 2);
        vm.prank(manager);
        uint256 id = t.queue(asset, dest, amount);
        gExpiry[id] = block.timestamp + t.delay() + 14 days;
        if (!t.isTracked(asset)) _bad("queued asset not tracked");
    }

    function cancel(uint256 id) external {
        uint256 n = t.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (,,,,, bool done) = t.withdrawals(id);
        vm.prank(manager);
        if (done) vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.cancel(id);
    }

    function execute(uint256 id) external {
        uint256 n = t.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (address asset,, uint256 amount, uint64 queuedAt, uint64 expiresAt, bool done) = t.withdrawals(id);
        if (expiresAt != gExpiry[id]) _bad("expiry moved");
        bool shared = asset != address(other);
        uint256 sharedBefore = main.balanceOf(address(t));
        uint256 otherBefore = other.balanceOf(address(t));
        uint16 rateNow = t.rateBps();
        try t.execute(id) {
            executions++;
            if (done) _bad("executed twice");
            if (block.timestamp < uint256(queuedAt) + t.delay()) _bad("before the delay");
            if (block.timestamp > expiresAt) _bad("after the expiry");
            uint256 sharedOut = sharedBefore - main.balanceOf(address(t));
            uint256 otherOut = otherBefore - other.balanceOf(address(t));
            if (shared) {
                if (sharedOut != amount || otherOut != 0) _bad("wrong balance moved");
                withdrawnShared += amount;
                uint256 epoch = block.timestamp / 7 days;
                if (epoch != gEpoch) {
                    gEpoch = epoch;
                    gStartBal = sharedBefore;
                    gRate = rateNow;
                    gSpent = 0;
                }
                gSpent += amount;
                // one 25% window per balance, whichever of its addresses is used
                if (gSpent * 10_000 > gStartBal * gRate) _bad("shared balance over its weekly cap");
            } else {
                if (otherOut != amount || sharedOut != 0) _bad("wrong balance moved");
                withdrawnOther += amount;
            }
        } catch (bytes memory err) {
            if (bytes4(err) == TreasuryVault.OverWeeklyCap.selector) refusedOverCap++;
        }
    }

    function decreaseRate(uint256 r) external {
        uint16 cur = t.rateBps();
        if (cur == 1) return;
        // small steps, so a run keeps a usable rate for long enough to reach the cap
        uint16 nr = uint16(bound(r, cur > 100 ? cur - 100 : 1, cur - 1));
        vm.prank(manager);
        t.decreaseRate(nr);
    }

    function increaseDelay(uint256 d) external {
        uint64 cur = t.delay();
        if (cur == 30 days) return;
        // small steps, so most queued withdrawals stay executable before their fixed expiry
        uint64 nd = uint64(bound(d, cur + 1, cur + 6 hours > 30 days ? 30 days : cur + 6 hours));
        vm.prank(manager);
        t.increaseDelay(nd);
    }
}

contract SharedCapInvariantTest is Test {
    SharedCapHandler h;
    TreasuryVault t;
    ShMain main;
    ShLegacy legacy;
    ShToken other;
    address manager = makeAddr("manager");

    function setUp() public {
        vm.warp(1_760_000_000);
        main = new ShMain();
        legacy = new ShLegacy(main);
        main.setLegacy(address(legacy));
        other = new ShToken("OTHER");
        VaultFactory f = new VaultFactory(IERC20(address(0)), address(0));
        t = f.createTreasury(address(0), manager, 1 days, 2500, new address[](0));
        main.mint(address(t), 1_000_000e18);
        other.mint(address(t), 1_000_000e18);
        h = new SharedCapHandler(t, main, legacy, other, manager);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = h.warp.selector;
        sel[1] = h.deposit.selector;
        sel[2] = h.queue.selector;
        sel[3] = h.cancel.selector;
        sel[4] = h.execute.selector;
        sel[5] = h.decreaseRate.selector;
        sel[6] = h.increaseDelay.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    function _held() internal view returns (uint256 shared, uint256 oth) {
        shared = 1_000_000e18 + h.depositedShared() - h.withdrawnShared();
        oth = 1_000_000e18 + h.depositedOther() - h.withdrawnOther();
    }

    /// @dev Not vacuous: a fixed sequence executes through one address and is refused through the other.
    function test_HandlerReachesBothSidesOfTheSharedCap() public {
        h.queue(0, type(uint256).max); // main, bounded to a quarter of the balance + 2 wei: over the cap
        h.queue(0, 250_000e18 - 1); // main, one wei under the cap
        h.queue(1, 2); // legacy, 2 wei
        h.warp(1 days);
        h.execute(0);
        assertEq(h.refusedOverCap(), 1);
        h.execute(1);
        assertEq(h.executions(), 1);
        h.execute(2);
        assertEq(h.executions(), 1, "legacy refused: main left one wei in the shared window");
        assertEq(h.refusedOverCap(), 2);
        invariant_sharedCap();
        invariant_conservation();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_sharedCap() public view {
        assertFalse(h.violated(), h.why());
        (uint256 capMain, uint256 spentMain) = _window(address(main));
        (uint256 capLegacy, uint256 spentLegacy) = _window(address(legacy));
        assertLe(spentMain, capMain);
        assertLe(spentLegacy, capLegacy);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_conservation() public view {
        (uint256 shared, uint256 oth) = _held();
        assertEq(main.balanceOf(address(t)), shared, "shared balance held");
        assertEq(other.balanceOf(address(t)), oth, "other balance held");
        assertEq(main.balanceOf(h.dest()), h.withdrawnShared());
        assertEq(other.balanceOf(h.dest()), h.withdrawnOther());
        assertLe(t.trackedAssets().length, 3);
    }

    function _window(address a) internal view returns (uint256 cap, uint256 spent) {
        (, cap, spent) = t.windows(a);
    }
}

/// @notice Boundaries of the second-round treasury changes: fixed expiry, the shared window, the manager's ETA.
contract SharedCapEdgeTest is Test {
    address manager = makeAddr("manager");
    address dest = makeAddr("dest");
    address stranger = makeAddr("stranger");
    VaultFactory f;
    ShMain main;
    ShLegacy legacy;
    TreasuryVault t;

    function setUp() public {
        vm.warp(1_760_000_000);
        f = new VaultFactory(IERC20(address(0)), address(0));
        main = new ShMain();
        legacy = new ShLegacy(main);
        main.setLegacy(address(legacy));
        t = f.createTreasury(address(main), manager, 1 days, 2500, new address[](0));
        main.mint(address(t), 1000e18);
    }

    function test_ExpiryIsInclusiveAndOneSecondLaterRefused() public {
        uint64 t0 = uint64(block.timestamp);
        vm.startPrank(manager);
        uint256 a = t.queue(address(main), dest, 1e18);
        uint256 b = t.queue(address(main), dest, 1e18);
        vm.stopPrank();
        (,,,, uint64 expiresAt,) = t.withdrawals(a);
        assertEq(expiresAt, t0 + 15 days);
        vm.warp(expiresAt);
        t.execute(a);
        vm.warp(expiresAt + 1);
        vm.expectRevert(TreasuryVault.Expired.selector);
        t.execute(b);
        // cancelling an expired withdrawal is still allowed, and then it is done for good
        vm.prank(manager);
        t.cancel(b);
        vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.execute(b);
    }

    function test_IncreaseDelayShortensButKeepsAnOpenWindow() public {
        uint64 t0 = uint64(block.timestamp);
        vm.prank(manager);
        uint256 id = t.queue(address(main), dest, 1e18);
        vm.prank(manager);
        t.increaseDelay(15 days); // due == expiry: exactly one second to execute
        vm.warp(t0 + 15 days - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, t0 + 15 days));
        t.execute(id);
        vm.warp(t0 + 15 days);
        t.execute(id);
        assertEq(main.balanceOf(dest), 1e18);
    }

    function testFuzz_ExpiryNeverMovesWithTheDelay(uint64 d0, uint64 d1, uint256 wait) public {
        d0 = uint64(bound(d0, 1 days, 29 days));
        vm.prank(stranger);
        TreasuryVault v = f.createTreasury(address(main), manager, d0, 2500, new address[](0));
        main.mint(address(v), 100e18);
        uint64 t0 = uint64(block.timestamp);
        vm.prank(manager);
        uint256 id = v.queue(address(main), dest, 1e18);
        d1 = uint64(bound(d1, d0 + 1, 30 days));
        vm.prank(manager);
        v.increaseDelay(d1);
        (,,,, uint64 expiresAt,) = v.withdrawals(id);
        assertEq(expiresAt, t0 + d0 + 14 days);
        vm.warp(t0 + bound(wait, 0, 60 days));
        bool ok = block.timestamp >= t0 + d1 && block.timestamp <= expiresAt;
        if (!ok) vm.expectRevert();
        v.execute(id);
        assertEq(main.balanceOf(dest), ok ? 1e18 : 0);
    }

    function test_QueueingTheSameAssetTwiceTracksItOnceAndEthNever() public {
        vm.startPrank(manager);
        t.queue(address(main), dest, 1);
        t.queue(address(main), dest, 1);
        t.queue(address(0), dest, 1);
        t.queue(address(legacy), dest, 1);
        vm.stopPrank();
        address[] memory tr = t.trackedAssets();
        assertEq(tr.length, 2);
        assertEq(tr[0], address(main));
        assertEq(tr[1], address(legacy));
        assertFalse(t.isTracked(address(0)));
        // only the manager can grow the tracked set
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(address(stranger), dest, 1);
        assertEq(t.trackedAssets().length, 2);
    }

    function test_SharedChargeOpensTheOtherWindowAtTheLowerRate() public {
        vm.startPrank(manager);
        uint256 a = t.queue(address(main), dest, 100e18);
        uint256 b = t.queue(address(legacy), dest, 1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        t.execute(a); // main window: cap 250, spent 100; legacy window: cap 250, spent 100
        vm.prank(manager);
        t.decreaseRate(1000); // already-open windows keep their cap this epoch
        t.execute(b);
        assertEq(t.availableThisWeek(address(main)), 149e18);
        assertEq(t.availableThisWeek(address(legacy)), 149e18);
        // next epoch, both windows open at 10% of what is left
        vm.warp((block.timestamp / 7 days + 1) * 7 days);
        vm.prank(manager);
        uint256 c = t.queue(address(legacy), dest, 89.9e18 + 1);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 89.9e18));
        t.execute(c);
    }

    function test_SharedWindowSpansEpochsCorrectly() public {
        // main is used at the end of one epoch, legacy at the start of the next: each epoch has its own 25%
        uint256 epochEnd = (block.timestamp / 7 days + 1) * 7 days;
        vm.warp(epochEnd - 2 days);
        vm.startPrank(manager);
        uint256 a = t.queue(address(main), dest, 250e18);
        uint256 b = t.queue(address(legacy), dest, 187.5e18);
        vm.stopPrank();
        vm.warp(epochEnd - 1);
        t.execute(a);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.OverWeeklyCap.selector, 0));
        t.execute(b);
        vm.warp(epochEnd);
        t.execute(b);
        assertEq(main.balanceOf(dest), 437.5e18, "the documented 43.75% across one boundary");
        assertEq(t.availableThisWeek(address(main)), 0);
    }

    function test_UnreadableTrackedAssetIsSkippedEitherWay() public {
        ShBroken brk = new ShBroken();
        brk.mint(address(t), 100e18);
        vm.startPrank(manager);
        uint256 a = t.queue(address(brk), dest, 1e18);
        uint256 m = t.queue(address(main), dest, 250e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        brk.setBroken(true);
        t.execute(m); // the unreadable tracked asset does not block the main token
        assertEq(main.balanceOf(dest), 250e18);
        // the unreadable asset itself can not leave: its own balance read reverts
        vm.expectRevert(bytes("broken"));
        t.execute(a);
        brk.setBroken(false);
        t.execute(a);
        assertEq(brk.balanceOf(dest), 1e18);
    }

    function test_PendingManagerEtaResetsOnReproposeAndClearsOnCancel() public {
        assertEq(t.pendingManagerEta(), 0);
        uint64 t0 = uint64(block.timestamp);
        vm.prank(manager);
        t.proposeManager(stranger);
        vm.warp(t0 + 1 days - 1);
        vm.prank(manager);
        t.proposeManager(stranger); // proposing again restarts the clock
        assertEq(t.pendingManagerEta(), t0 + 2 days - 1);
        vm.warp(t0 + 1 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.TooEarly.selector, t0 + 2 days - 1));
        t.acceptManager();
        vm.prank(manager);
        t.cancelManager();
        assertEq(t.pendingManagerEta(), 0);
        assertEq(t.pendingManagerProposedAt(), 0);
        vm.warp(t0 + 30 days);
        vm.prank(stranger);
        vm.expectRevert(TreasuryVault.NoProposal.selector);
        t.acceptManager();
        assertEq(t.manager(), manager);
    }

    function test_CreatorIsRecordedForEveryPathAndFreeVaultsStillCarryIt() public {
        ShToken imd = new ShToken("IMD");
        address radar = makeAddr("radar");
        VaultFactory paid = new VaultFactory(IERC20(address(imd)), radar);
        imd.mint(manager, 10e18);
        vm.prank(manager);
        imd.approve(address(paid), type(uint256).max);
        vm.prank(manager);
        TreasuryVault openT = paid.createTreasury(address(0), manager, 1 days, 2500, new address[](0));
        assertEq(paid.creatorOf(address(openT)), manager);
        assertTrue(paid.feePaid(block.chainid, address(openT)));
        // a stranger without IMD can not open a second, unpaid, open treasury: each one is keyed to itself
        vm.prank(stranger);
        vm.expectRevert();
        paid.createTreasury(address(0), stranger, 1 days, 2500, new address[](0));
        assertEq(paid.vaultCount(), 1);
    }
}
