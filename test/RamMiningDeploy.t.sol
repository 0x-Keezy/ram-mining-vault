// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable, IRamSwapRouter} from "../src/RamMiningVault.sol";
import {TestNvdaToken} from "../src/TestNvdaToken.sol";
import {VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";

contract DeploySwapRouter is IRamSwapRouter {
    TestNvdaToken public reward;
    address public wbnb = address(0x1111);

    constructor(TestNvdaToken _reward) {
        reward = _reward;
    }

    function WETH() external view override returns (address) {
        return wbnb;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // mock 1:1 quote, matches swapExactETHForTokens
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        payable
        override
        returns (uint256[] memory amounts)
    {
        uint256 out = msg.value;
        require(out >= amountOutMin, "slippage");
        reward.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }
}

/// @notice End-to-end testnet-launch simulation: deploy factory + reward + router, launch a vault via the
///         (pranked) VaultPortal, run fee->swap->distribute->claim, and read back the on-chain config — the
///         local mirror of the broadcast the user will run with their funded testnet key.
contract RamMiningDeployTest is Test {
    address constant BNB_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant RAM_TOKEN = address(0x4A11);

    address miner = address(0xA11CE);

    TestNvdaToken reward;
    DeploySwapRouter router;
    RamMiningBeaconFactory factory;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days);
        reward = new TestNvdaToken();
        router = new DeploySwapRouter(reward);
        factory = new RamMiningBeaconFactory();
    }

    function testFactoryReadback() public view {
        // mirrors the documented on-chain readback for the RAM launch
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 4);
        assertEq(s.fields[0].name, "rewardToken");
        assertEq(s.fields[1].name, "swapRouter");
        assertEq(s.fields[2].name, "basePriceWei");
        assertEq(s.fields[3].name, "seasonEnd");

        assertTrue(factory.beacon() != address(0));
        assertTrue(factory.beaconImplementation() != address(0));
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(reward)));
        assertFalse(factory.isVaultUpgradesLocked());
    }

    function testEndToEndLaunchAndFlow() public {
        uint256 basePrice = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData = abi.encode(address(reward), address(router), basePrice, seasonEnd);

        // launch through the VaultPortal (as Flap would)
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable vault =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vaultData)));

        assertEq(vault.rewardToken(), address(reward));
        assertEq(vault.swapRouter(), address(router));
        assertEq(vault.basePriceWei(), basePrice);

        // a miner buys a rig
        vm.deal(miner, 1 ether);
        vm.prank(miner);
        vault.buyMiningContract{value: basePrice}(0);

        // simulate trading fees arriving as BNB, then deploy into tNVDA and distribute
        vm.deal(address(vault), 5 ether);
        vm.prank(GUARDIAN);
        uint256 out = vault.deployToReward(2 ether, 1 ether);
        assertEq(out, 2 ether);

        // miner claims real (mock) NVDA
        assertApproxEqAbs(vault.pendingRewards(miner), 2 ether, 100);
        vm.prank(miner);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(reward.balanceOf(miner), got, 100);
        assertApproxEqAbs(got, 2 ether, 100);
    }
}
