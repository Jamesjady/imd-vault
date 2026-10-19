// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VestingVault} from "../src/VestingVault.sol";

/// @notice Runs against the real IMD token on an Ethereum fork. Skipped unless FORK_RPC is set:
///         FORK_RPC=https://rpc.mevblocker.io forge test --match-contract Fork
contract ForkTest is Test {
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    address constant RADAR = address(0x5ad4);

    function test_RealImdFeeAndVesting() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        VaultFactory factory = new VaultFactory(IMD, RADAR);
        address project = makeAddr("project");
        address team = makeAddr("team");
        deal(address(IMD), project, 1005e18);

        uint256 radarBefore = IMD.balanceOf(RADAR);
        vm.startPrank(project);
        IMD.approve(address(factory), type(uint256).max);
        VestingVault v = factory.createVesting(IMD, team, 1000e18, uint64(block.timestamp), 0, 30 days);
        vm.stopPrank();

        assertEq(IMD.balanceOf(RADAR) - radarBefore, 5e18);
        assertEq(IMD.balanceOf(address(v)), 1000e18);
        vm.warp(block.timestamp + 30 days);
        v.release();
        assertEq(IMD.balanceOf(team), 1000e18);
    }
}
