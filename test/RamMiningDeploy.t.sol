// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {TestNvdaToken} from "../src/TestNvdaToken.sol";
import {VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";

/// @dev Minimal Chainlink feed mock (8 dec) for the deploy simulation.
contract DeployPriceFeed {
    uint8 public decimals = 8;
    int256 internal _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice End-to-end testnet-launch simulation: deploy factory + reward + feeds, launch a vault via the
///         (pranked) VaultPortal, run a keeper RFQ fill (NVDA sold INTO the vault for BNB) → distribute → claim,
///         and read back the on-chain config — the local mirror of the broadcast the user runs with their key.
contract RamMiningDeployTest is Test {
    address constant BNB_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant RAM_TOKEN = address(0x4A11);
    address constant TREASURY = address(0x7E57);

    address miner = address(0xA11CE);
    address keeper = address(0xCAFE);

    TestNvdaToken reward;
    DeployPriceFeed nvdaFeed;
    DeployPriceFeed bnbFeed;
    RamMiningBeaconFactory factory;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days);
        reward = new TestNvdaToken();
        nvdaFeed = new DeployPriceFeed(130e8);
        bnbFeed = new DeployPriceFeed(600e8);
        factory = new RamMiningBeaconFactory();
    }

    function testFactoryReadback() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 9);
        assertEq(s.fields[0].name, "rewardToken");
        assertEq(s.fields[1].name, "rewardPriceFeed");
        assertEq(s.fields[2].name, "bnbPriceFeed");
        assertEq(s.fields[3].name, "basePriceWei");
        assertEq(s.fields[4].name, "seasonEnd");
        assertEq(s.fields[5].name, "ramPriceOracle");
        assertEq(s.fields[6].name, "ramCageMin");
        assertEq(s.fields[7].name, "ramCageMax");
        assertEq(s.fields[8].name, "ramTreasuryWallet");

        assertTrue(factory.beacon() != address(0));
        assertTrue(factory.beaconImplementation() != address(0));
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(reward)));
        assertFalse(factory.isVaultUpgradesLocked());
    }

    function testEndToEndLaunchAndFlow() public {
        uint256 basePrice = 0.001 ether;
        uint256 seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0, TREASURY);

        // launch through the VaultPortal (as Flap would)
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable vault =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vaultData)));

        assertEq(vault.rewardToken(), address(reward));
        assertEq(vault.rewardPriceFeed(), address(nvdaFeed));
        assertEq(vault.bnbPriceFeed(), address(bnbFeed));
        assertEq(vault.basePriceWei(), basePrice);

        // a miner buys a rig
        vm.deal(miner, 1 ether);
        vm.prank(miner);
        vault.buyMiningContract{value: basePrice}(0);

        // guardian arms the deviation band reference (required) then the egress caps; simulate BNB fees arriving
        vm.prank(GUARDIAN);
        vault.setReferencePrice(130e8);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(100 ether, 100 ether);
        vm.deal(address(vault), 5 ether);

        // a keeper sells NVDA into the vault at the oracle price + premium
        uint256 amount = 2e18;
        uint256 quoted = vault.quoteRWAToVault(amount);
        reward.mint(keeper, amount);
        vm.startPrank(keeper);
        reward.approve(address(vault), amount);
        uint256 owed = vault.sellRWAToVault(amount, 0);
        vm.stopPrank();
        assertEq(owed, quoted);
        assertEq(keeper.balance, quoted);

        // miner claims the real (mock) NVDA
        assertApproxEqAbs(vault.pendingRewards(miner), amount, 100);
        vm.prank(miner);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(reward.balanceOf(miner), got, 100);
        assertApproxEqAbs(got, amount, 100);
    }
}
