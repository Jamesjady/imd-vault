// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract InvToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================================================
//                                                 vesting
// ============================================================================================================

/// @dev Drives one bnd vault (token A) and one open vault (tokens B and C, arriving at random moments) with
///      warps, top-ups, syncs, releases by anyone, duration extensions and beneficiary handovers.
contract VestingHandler is Test {
    VestingVault public bnd;
    VestingVault public open;
    InvToken public a;
    InvToken public b;
    InvToken public c;

    address[3] public actors;
    address public funder = makeAddr("funder");

    // ghost accounting, per vault and token
    mapping(address => mapping(address => uint256)) public deposited;
    mapping(address => mapping(address => uint256)) public paidOut; // to any beneficiary
    mapping(address => uint64) public lastDuration;
    mapping(address => mapping(address => uint64)) public firstArrival;
    /// @dev Set when a release paid out before the unlock start or more than was vested.
    bool public earlyRelease;
    uint256 public releases;

    constructor(
        VestingVault bound_,
        VestingVault open_,
        InvToken a_,
        InvToken b_,
        InvToken c_,
        address[3] memory actors_
    ) {
        bnd = bound_;
        open = open_;
        a = a_;
        b = b_;
        c = c_;
        actors = actors_;
        lastDuration[address(bnd)] = bnd.duration();
        lastDuration[address(open)] = open.duration();
        deposited[address(bnd)][address(a)] = a.balanceOf(address(bnd));
    }

    function _vault(uint256 i) internal view returns (VestingVault) {
        return i % 2 == 0 ? bnd : open;
    }

    function _asset(VestingVault v, uint256 i) internal view returns (InvToken) {
        if (v == bnd) return a;
        return i % 2 == 0 ? b : c;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 21 days));
    }

    function topUp(uint256 vi, uint256 ai, uint256 amount) external {
        VestingVault v = _vault(vi);
        InvToken t = _asset(v, ai);
        amount = bound(amount, 1, 1e27);
        t.mint(address(v), amount);
        deposited[address(v)][address(t)] += amount;
    }

    function sync(uint256 ai) external {
        InvToken t = _asset(open, ai);
        uint64 before = open.arrivedAt(address(t));
        if (t.balanceOf(address(open)) == 0) {
            vm.expectRevert();
            this.callSync(address(t));
            return;
        }
        open.sync(address(t));
        if (before == 0) firstArrival[address(open)][address(t)] = uint64(block.timestamp);
    }

    /// @dev sync with nothing held must not start the clock: wrapper so the handler can assert on it.
    function callSync(address t) external {
        open.sync(t);
        if (open.arrivedAt(t) == 0) revert("no clock");
    }

    function release(uint256 vi, uint256 ai, uint256 callerI) external {
        VestingVault v = _vault(vi);
        InvToken t = _asset(v, ai);
        address ben = v.beneficiary();
        uint256 before = t.balanceOf(ben);
        uint64 arrivedBefore = v.arrivedAt(address(t));
        uint256 releasedBefore = v.released(address(t));
        vm.prank(actors[callerI % 3]);
        try v.release(address(t)) {
            uint256 got = t.balanceOf(ben) - before;
            if (arrivedBefore == 0 && v.arrivedAt(address(t)) != 0) {
                firstArrival[address(v)][address(t)] = uint64(block.timestamp);
            }
            if (got > 0) {
                releases++;
                if (block.timestamp < v.unlockStart(address(t))) earlyRelease = true;
                if (v.released(address(t)) != releasedBefore + got) earlyRelease = true;
                if (v.released(address(t)) > v.vestedAmount(address(t), uint64(block.timestamp))) earlyRelease = true;
            }
            paidOut[address(v)][address(t)] += got;
        } catch {}
    }

    function extend(uint256 vi, uint256 extra) external {
        VestingVault v = _vault(vi);
        uint64 d = v.duration();
        uint64 nd = uint64(bound(extra, 0, 60 days)) + d;
        vm.prank(v.beneficiary());
        if (nd == d) {
            vm.expectRevert(VestingVault.NotLonger.selector);
            v.extendDuration(nd);
            return;
        }
        v.extendDuration(nd);
        lastDuration[address(v)] = nd;
    }

    function strangerExtendOrPropose(uint256 vi, uint256 ai) external {
        VestingVault v = _vault(vi);
        address s = actors[ai % 3];
        if (s == v.beneficiary()) return;
        vm.prank(s);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.proposeBeneficiary(s);
        vm.prank(s);
        vm.expectRevert(VestingVault.NotBeneficiary.selector);
        v.extendDuration(type(uint32).max);
    }

    function propose(uint256 vi, uint256 ai) external {
        VestingVault v = _vault(vi);
        vm.prank(v.beneficiary());
        v.proposeBeneficiary(actors[ai % 3]);
    }

    function accept(uint256 vi) external {
        VestingVault v = _vault(vi);
        address p = v.pendingBeneficiary();
        if (p == address(0)) return;
        uint64 eta = v.pendingBeneficiaryEta();
        vm.prank(p);
        if (block.timestamp < eta) {
            vm.expectRevert(abi.encodeWithSelector(VestingVault.TooEarly.selector, eta));
            v.acceptBeneficiary();
            return;
        }
        v.acceptBeneficiary();
    }

    function recoverVested() external {
        vm.expectRevert(VestingVault.VestingToken.selector);
        bnd.recover(IERC20(address(a)));
        vm.expectRevert(VestingVault.VestingToken.selector);
        open.recover(IERC20(address(b)));
    }
}

contract VestingInvariantTest is Test {
    VestingHandler h;
    VestingVault bnd;
    VestingVault open;
    InvToken a;
    InvToken b;
    InvToken c;
    address[3] actors;

    function setUp() public {
        vm.warp(1_760_000_000);
        actors = [makeAddr("team"), makeAddr("heir"), makeAddr("stranger")];
        InvToken imd = new InvToken("IMD");
        a = new InvToken("A");
        b = new InvToken("B");
        c = new InvToken("C");
        VaultFactory factory = new VaultFactory(IERC20(address(imd)), makeAddr("radar"));
        address project = makeAddr("project");
        imd.mint(project, 10e18);
        a.mint(project, 1e24);
        vm.startPrank(project);
        imd.approve(address(factory), type(uint256).max);
        a.approve(address(factory), type(uint256).max);
        bnd = factory.createVesting(
            IERC20(address(a)), actors[0], 1e24, uint64(block.timestamp + 3 days), 10 days, 28 days
        );
        open = factory.createLaunchVesting(actors[0], uint64(block.timestamp + 1 days), 5 days, 35 days);
        vm.stopPrank();

        h = new VestingHandler(bnd, open, a, b, c, actors);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = h.warp.selector;
        sel[1] = h.topUp.selector;
        sel[2] = h.sync.selector;
        sel[3] = h.release.selector;
        sel[4] = h.extend.selector;
        sel[5] = h.propose.selector;
        sel[6] = h.accept.selector;
        sel[7] = h.recoverVested.selector;
        sel[8] = h.strangerExtendOrPropose.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    function _each(function(VestingVault, address) internal view check) internal view {
        check(bnd, address(a));
        check(open, address(b));
        check(open, address(c));
    }

    /// what the vault holds plus what it paid equals what it received, and every payout went to a beneficiary
    function _conservation(VestingVault v, address t) internal view {
        assertEq(IERC20(t).balanceOf(address(v)) + v.released(t), h.deposited(address(v), t), "conservation");
        assertEq(v.released(t), h.paidOut(address(v), t), "released == paid to beneficiaries");
        uint256 toBeneficiaries;
        for (uint256 i; i < 3; ++i) {
            toBeneficiaries += IERC20(t).balanceOf(actors[i]);
        }
        assertEq(toBeneficiaries, v.released(t), "no token leaves to anyone else");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// @dev The handler is not vacuous: a fixed sequence pays both vaults out.
    function test_HandlerReachesRelease() public {
        h.topUp(1, 0, 1e24);
        h.sync(0);
        h.warp(21 days);
        h.release(0, 0, 2);
        h.release(1, 0, 2);
        assertEq(h.releases(), 2);
        invariant_conservation();
        invariant_schedule();
        invariant_openVaultClock();
    }

    function invariant_conservation() public view {
        // the two vaults share no token, so actor balances of a token are that vault's payouts
        _each(_conservation);
    }

    function _schedule(VestingVault v, address t) internal view {
        uint64 nowTs = uint64(block.timestamp);
        uint256 total = v.totalAllocation(t);
        uint256 vested = v.vestedAmount(t, nowTs);
        // a duration extension may lower `vested` below what was already released (checked at each release in
        // the handler); what can be taken now is then zero, never an underflow
        assertLe(v.released(t), total, "released <= total");
        assertEq(v.releasable(t), vested > v.released(t) ? vested - v.released(t) : 0, "releasable");
        assertLe(vested, total, "vested <= total");
        // nothing during the cliff
        if (nowTs < v.start() + v.cliff()) assertEq(vested, 0, "cliff");
        // never more than 25% of the allocation in any 7 days, from here
        uint256 next = v.vestedAmount(t, nowTs + 7 days);
        assertLe(next - vested, total / 4 + 1, "25% a week");
        // the duration can only grow, and never below 4 weeks
        assertGe(v.duration(), h.lastDuration(address(v)), "duration only grows");
        assertGe(v.duration(), 28 days, "min duration");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_schedule() public view {
        _each(_schedule);
    }

    function _clock(VestingVault v, address t) internal view {
        if (v == bnd) {
            assertEq(v.arrivedAt(t), 0, "bnd vault has no arrival clock");
            assertEq(v.unlockStart(t), v.start() + v.cliff());
            return;
        }
        uint64 at = v.arrivedAt(t);
        assertEq(at, h.firstArrival(address(v), t), "arrival is recorded once and never moves");
        if (at == 0) {
            assertEq(v.vestedAmount(t, type(uint64).max), 0, "nothing vests before arrival is recorded");
        } else {
            assertGe(v.unlockStart(t), at, "unlock no earlier than arrival");
            assertGe(v.unlockStart(t), v.start() + v.cliff(), "unlock no earlier than schedule");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_openVaultClock() public view {
        _each(_clock);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_noEarlyRelease() public view {
        assertFalse(h.earlyRelease(), "a release paid before unlock or beyond vested");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_immutables() public view {
        assertEq(address(bnd.token()), address(a));
        assertEq(address(open.token()), address(0));
        assertEq(bnd.beneficiaryDelay(), 7 days);
        assertEq(open.beneficiaryDelay(), 7 days);
    }
}

// ============================================================================================================
//                                                 treasury
// ============================================================================================================

contract EthSink {
    receive() external payable {}
}

/// @dev Drives one restricted treasury holding a token and ETH: deposits, queues (also to forbidden and
///      removed destinations), cancels, executions by anyone, rule tightening and warps.
contract TreasuryHandler is Test {
    TreasuryVault public t;
    InvToken public tok;
    address public manager;
    address[3] public dests;
    address public outsider = makeAddr("outsider");

    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    // weekly cap ghost, per asset: epoch, balance seen at its first execution, rate then, amount spent
    mapping(address => uint256) public gEpoch;
    mapping(address => uint256) public gStartBal;
    mapping(address => uint256) public gRate;
    mapping(address => uint256) public gSpent;
    uint64 public lastDelay;
    uint16 public lastRate;
    uint256 public lastDestCount;
    bool public violated;
    string public why;
    uint256 public executions;

    constructor(TreasuryVault t_, InvToken tok_, address manager_, address[3] memory dests_) {
        t = t_;
        tok = tok_;
        manager = manager_;
        dests = dests_;
        lastDelay = t.delay();
        lastRate = t.rateBps();
        lastDestCount = t.destinations().length;
    }

    function _asset(uint256 i) internal view returns (address) {
        return i % 2 == 0 ? address(tok) : address(0);
    }

    function _bad(string memory reason) internal {
        violated = true;
        why = reason;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
    }

    function deposit(uint256 ai, uint256 amount) external {
        address asset = _asset(ai);
        amount = bound(amount, 1, 1e24);
        if (asset == address(0)) {
            vm.deal(address(this), amount);
            (bool ok,) = address(t).call{value: amount}("");
            require(ok);
        } else {
            tok.mint(address(this), amount);
            tok.approve(address(t), amount);
            t.deposit(IERC20(address(tok)), amount);
        }
        deposited[asset] += amount;
    }

    function queue(uint256 ai, uint256 di, uint256 amount) external {
        address asset = _asset(ai);
        address to = di % 4 == 3 ? outsider : dests[di % 3];
        amount = bound(amount, 1, 1e24);
        bool allowed = t.isDestination(to);
        vm.prank(manager);
        if (!allowed) {
            vm.expectRevert(abi.encodeWithSelector(TreasuryVault.NotAllowed.selector, to));
            t.queue(asset, to, amount);
            return;
        }
        t.queue(asset, to, amount);
    }

    function strangerQueue(uint256 ai, uint256 amount) external {
        vm.prank(outsider);
        vm.expectRevert(TreasuryVault.NotManager.selector);
        t.queue(_asset(ai), dests[0], bound(amount, 1, 1e24));
    }

    function cancel(uint256 id) external {
        uint256 n = t.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (,,,, bool done) = t.withdrawals(id);
        vm.prank(manager);
        if (done) vm.expectRevert(TreasuryVault.AlreadyDone.selector);
        t.cancel(id);
    }

    function execute(uint256 id) external {
        uint256 n = t.withdrawalCount();
        if (n == 0) return;
        id = id % n;
        (address asset, address to, uint256 amount, uint64 queuedAt, bool done) = t.withdrawals(id);
        uint256 balBefore = asset == address(0) ? address(t).balance : tok.balanceOf(address(t));
        uint256 toBefore = asset == address(0) ? to.balance : tok.balanceOf(to);
        uint16 rateNow = t.rateBps();
        vm.prank(outsider);
        try t.execute(id) {
            executions++;
            if (done) _bad("executed twice or after cancel");
            if (block.timestamp < uint256(queuedAt) + t.delay()) _bad("executed before the delay");
            if (block.timestamp < uint256(queuedAt) + 1 days) _bad("executed before 24h");
            if (block.timestamp > uint256(queuedAt) + t.delay() + 14 days) _bad("executed after grace");
            if (!t.isDestination(to)) _bad("paid a destination not allowed");
            uint256 toAfter = asset == address(0) ? to.balance : tok.balanceOf(to);
            if (toAfter - toBefore != amount) _bad("destination did not get the amount");
            uint256 epoch = block.timestamp / 7 days;
            if (gEpoch[asset] != epoch || gRate[asset] == 0) {
                gEpoch[asset] = epoch;
                gStartBal[asset] = balBefore;
                gRate[asset] = rateNow;
                gSpent[asset] = 0;
            }
            gSpent[asset] += amount;
            if (gRate[asset] > 2500) _bad("rate above 25%");
            if (gSpent[asset] * 10_000 > gStartBal[asset] * gRate[asset]) _bad("weekly cap exceeded");
            withdrawn[asset] += amount;
        } catch {}
    }

    function increaseDelay(uint256 d) external {
        uint64 nd = uint64(bound(d, 0, 31 days));
        bool bad = nd <= t.delay() || nd > 30 days;
        vm.prank(manager);
        if (bad) {
            vm.expectRevert(TreasuryVault.BadDelay.selector);
            t.increaseDelay(nd);
            return;
        }
        t.increaseDelay(nd);
    }

    function decreaseRate(uint256 r) external {
        uint16 nr = uint16(bound(r, 0, 3000));
        bool bad = nr == 0 || nr >= t.rateBps();
        vm.prank(manager);
        if (bad) {
            vm.expectRevert(TreasuryVault.BadRate.selector);
            t.decreaseRate(nr);
            return;
        }
        t.decreaseRate(nr);
    }

    function removeDestination(uint256 di) external {
        address d = dests[di % 3];
        bool bad = !t.isDestination(d) || t.destinations().length == 1;
        vm.prank(manager);
        if (bad) {
            vm.expectRevert(TreasuryVault.NotListed.selector);
            t.removeDestination(d);
            return;
        }
        t.removeDestination(d);
    }

    function reopen() external {
        address[] memory l = new address[](1);
        l[0] = outsider;
        vm.prank(manager);
        vm.expectRevert(TreasuryVault.AlreadyRestricted.selector);
        t.restrictDestinations(l);
    }

    function snapshot() external {
        if (t.delay() < lastDelay) _bad("delay fell");
        if (t.rateBps() > lastRate) _bad("rate rose");
        if (t.destinations().length > lastDestCount) _bad("destinations grew");
        lastDelay = t.delay();
        lastRate = t.rateBps();
        lastDestCount = t.destinations().length;
    }

    receive() external payable {}
}

contract TreasuryInvariantTest is Test {
    TreasuryHandler h;
    TreasuryVault t;
    InvToken tok;
    address[3] dests;
    address manager = makeAddr("manager");

    function setUp() public {
        vm.warp(1_760_000_000);
        tok = new InvToken("T");
        dests = [address(new EthSink()), address(new EthSink()), address(new EthSink())];
        address[] memory list = new address[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = dests[i];
        }
        VaultFactory factory = new VaultFactory(IERC20(address(0)), address(0));
        t = factory.createTreasury(address(tok), manager, 1 days, 2500, list);
        h = new TreasuryHandler(t, tok, manager, dests);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = h.warp.selector;
        sel[1] = h.deposit.selector;
        sel[2] = h.queue.selector;
        sel[3] = h.cancel.selector;
        sel[4] = h.execute.selector;
        sel[5] = h.increaseDelay.selector;
        sel[6] = h.decreaseRate.selector;
        sel[7] = h.removeDestination.selector;
        sel[8] = h.reopen.selector;
        sel[9] = h.snapshot.selector;
        sel[10] = h.strangerQueue.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// @dev The handler is not vacuous: a short fixed sequence reaches a paid withdrawal and a refused one.
    function test_HandlerReachesExecution() public {
        h.deposit(0, 1000e18);
        h.queue(0, 0, 100e18);
        h.queue(0, 1, 900e18);
        h.warp(1 days);
        h.execute(0);
        h.execute(1);
        assertEq(h.executions(), 1);
        assertEq(h.withdrawn(address(tok)), 100e18);
        invariant_conservation();
        invariant_rulesBoundedAndStricter();
    }

    function invariant_conservation() public view {
        assertEq(tok.balanceOf(address(t)), h.deposited(address(tok)) - h.withdrawn(address(tok)), "token held");
        assertEq(address(t).balance, h.deposited(address(0)) - h.withdrawn(address(0)), "eth held");
        uint256 tokOut;
        uint256 ethOut;
        for (uint256 i; i < 3; ++i) {
            tokOut += tok.balanceOf(dests[i]);
            ethOut += dests[i].balance;
        }
        assertEq(tokOut, h.withdrawn(address(tok)), "only destinations receive tokens");
        assertEq(ethOut, h.withdrawn(address(0)), "only destinations receive eth");
        assertEq(tok.balanceOf(h.outsider()), 0);
        assertEq(h.outsider().balance, 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_rulesBoundedAndStricter() public view {
        assertFalse(h.violated(), h.why());
        assertGe(t.delay(), 1 days);
        assertLe(t.delay(), 30 days);
        assertGe(t.delay(), h.lastDelay());
        assertGt(t.rateBps(), 0);
        assertLe(t.rateBps(), 2500);
        assertLe(t.rateBps(), h.lastRate());
        assertTrue(t.restricted(), "never reopens");
        address[] memory d = t.destinations();
        assertGe(d.length, 1, "never frozen");
        assertLe(d.length, h.lastDestCount());
        for (uint256 i; i < d.length; ++i) {
            assertTrue(t.isDestination(d[i]));
            assertTrue(d[i] == dests[0] || d[i] == dests[1] || d[i] == dests[2], "only original destinations");
        }
        assertFalse(t.isDestination(h.outsider()));
        assertEq(t.manager(), manager, "manager never changes without a handover");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_windowNeverOverspent() public view {
        address[2] memory assets = [address(tok), address(0)];
        for (uint256 i; i < 2; ++i) {
            (, uint256 cap, uint256 spent) = t.windows(assets[i]);
            assertLe(spent, cap, "spent <= cap");
            assertLe(t.availableThisWeek(assets[i]) * 10_000, _bal(assets[i]) * 2500 + 10_000, "available <= 25%");
        }
    }

    function _bal(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(t).balance : tok.balanceOf(address(t));
    }
}

// ============================================================================================================
//                                                 factory fees
// ============================================================================================================

contract FactoryHandler is Test {
    VaultFactory public f;
    InvToken public imd;
    InvToken[3] public tokens;
    address[3] public payers;
    address public radar;

    uint256 public expectedFees;
    uint256 public created;
    mapping(address => bool) public keyed; // project token or vault paid on this chain
    address[] public vaults;
    bool public violated;

    constructor(VaultFactory f_, InvToken imd_, InvToken[3] memory tokens_, address[3] memory payers_, address radar_) {
        f = f_;
        imd = imd_;
        tokens = tokens_;
        payers = payers_;
        radar = radar_;
    }

    function _fund(address p) internal {
        imd.mint(p, 5e18);
        vm.prank(p);
        imd.approve(address(f), type(uint256).max);
    }

    function _after(address key, address vault, uint256 radarBefore) internal {
        uint256 paid = imd.balanceOf(radar) - radarBefore;
        if (keyed[key]) {
            if (paid != 0) violated = true; // charged twice
        } else {
            if (paid != 5e18) violated = true;
            keyed[key] = true;
            expectedFees += 5e18;
        }
        if (!f.feePaid(block.chainid, key)) violated = true;
        vaults.push(vault);
        created++;
    }

    function createVesting(uint256 pi, uint256 ti, uint256 amount) external {
        address p = payers[pi % 3];
        InvToken t = tokens[ti % 3];
        amount = bound(amount, 1, 1e24);
        _fund(p);
        t.mint(p, amount);
        vm.startPrank(p);
        t.approve(address(f), amount);
        uint256 before = imd.balanceOf(radar);
        VestingVault v = f.createVesting(IERC20(address(t)), p, amount, uint64(block.timestamp), 0, 28 days);
        vm.stopPrank();
        if (t.balanceOf(address(v)) != amount) violated = true;
        _after(address(t), address(v), before);
    }

    function createLaunchVesting(uint256 pi) external {
        address p = payers[pi % 3];
        _fund(p);
        uint256 before = imd.balanceOf(radar);
        vm.prank(p);
        VestingVault v = f.createLaunchVesting(p, uint64(block.timestamp + 1), 0, 28 days);
        _after(address(v), address(v), before);
    }

    function createTreasury(uint256 pi, uint256 ti, bool openOne) external {
        address p = payers[pi % 3];
        address pt = openOne ? address(0) : address(tokens[ti % 3]);
        _fund(p);
        uint256 before = imd.balanceOf(radar);
        vm.prank(p);
        TreasuryVault v = f.createTreasury(pt, p, 1 days, 2500, new address[](0));
        _after(pt == address(0) ? address(v) : pt, address(v), before);
    }

    function payFor(uint256 pi, uint256 chainSel, uint256 ti) external {
        address p = payers[pi % 3];
        uint256 chainId = chainSel % 2 == 0 ? 4663 : block.chainid;
        address key = address(tokens[ti % 3]);
        _fund(p);
        uint256 before = imd.balanceOf(radar);
        bool already = f.feePaid(chainId, key);
        vm.prank(p);
        if (already) {
            vm.expectRevert(VaultFactory.AlreadyPaid.selector);
            f.payFor(chainId, key);
            return;
        }
        f.payFor(chainId, key);
        if (imd.balanceOf(radar) - before != 5e18) violated = true;
        expectedFees += 5e18;
        if (chainId == block.chainid) keyed[key] = true;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return vaults[i];
    }
}

contract FactoryInvariantTest is Test {
    FactoryHandler h;
    VaultFactory f;
    InvToken imd;
    InvToken[3] tokens;
    address radar = makeAddr("radar");

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = new InvToken("IMD");
        tokens = [new InvToken("X"), new InvToken("Y"), new InvToken("Z")];
        f = new VaultFactory(IERC20(address(imd)), radar);
        address[3] memory payers = [makeAddr("p0"), makeAddr("p1"), makeAddr("p2")];
        h = new FactoryHandler(f, imd, tokens, payers, radar);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](4);
        sel[0] = h.createVesting.selector;
        sel[1] = h.createLaunchVesting.selector;
        sel[2] = h.createTreasury.selector;
        sel[3] = h.payFor.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_feesAndRegistry() public view {
        assertFalse(h.violated(), "fee charged wrongly or vault misfunded");
        assertEq(imd.balanceOf(radar), h.expectedFees(), "radar holds exactly the fees");
        assertEq(imd.balanceOf(address(f)), 0, "factory holds no IMD");
        for (uint256 i; i < 3; ++i) {
            assertEq(tokens[i].balanceOf(address(f)), 0, "factory holds no tokens");
        }
        assertEq(f.vaultCount(), h.created(), "registry counts every vault");
        for (uint256 i; i < h.created(); ++i) {
            address v = h.vaultAt(i);
            assertTrue(f.isVault(v));
            assertEq(f.allVaults(i), v);
        }
    }
}
