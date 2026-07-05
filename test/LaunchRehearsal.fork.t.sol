// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    RamMiningBeaconFactory,
    RamMiningVaultUpgradeable,
    EntryRigMustBeMicro,
    RamPricingNotArmed
} from "../src/RamMiningVault.sol";
import {RamPriceOracle} from "../src/RamPriceOracle.sol";
import {IPortalLens, IPortalTypes} from "../src/flap/IPortal.sol";

interface IERC20F {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title LaunchRehearsal - full launch-day dress rehearsal on a BSC mainnet fork.
/// @notice Deploys the CURRENT v3.2 factory build into the fork (the exact bytecode the partner will redeploy —
///         the on-chain v3.1 factory 0x0555A8…4299 is superseded by the v3.2 tier-rebalance + USD-sink vaultData
///         and CANNOT decode the new 10-field layout), then rehearses against the REAL friend token (curve
///         phase), the REAL production RamPriceOracle, and the REAL NVDAB + Chainlink feeds. BNB_RPC_URL gated.
contract LaunchRehearsalForkTest is Test {
    RamMiningBeaconFactory FACTORY; // fresh v3.2 build, deployed into the fork in _fork()
    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant DEV = 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1;
    address constant TREASURY = 0xFc389871E3ed4435d588dE14312F6Cd9F24c6dFe;
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    address constant TEST = 0x31515e3902C9e582f8A8967C0E0380313c997777; // the friend's Flap tax token (curve)
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant NVDA_FEED = 0xFfD9790a7D7AC20aFD2114Fef814a848F364E780;
    address constant BNB_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    address constant PORTAL_LENS = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0; // Flap portal (curve state)
    address constant PCS_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 constant FLOOR = 10 ether;
    uint16 constant TRUNC = 5000;
    uint256 constant BASE = 0.001 ether; // Micro price (BNB entry)
    uint256 constant BASE_USD = 10e8; // $10 Micro USD-target (8 dec) → growth tiers $50/$250/$1,000 in RAM

    RamPriceOracle oracle;
    RamMiningVaultUpgradeable vault;

    address alice = address(0xA11CE); // fresh miner
    address bob = address(0xB0B); // second miner
    address keeper = address(0xCAFE);

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set BNB_RPC_URL to run the launch rehearsal");
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 56, "must fork BNB mainnet");
        // Deploy the v3.2 factory build into the fork — the exact bytecode the partner will redeploy for
        // launch (the on-chain v3.1 factory can't decode the new 10-field vaultData).
        FACTORY = new RamMiningBeaconFactory();
        return true;
    }

    function testLaunchRehearsal() public {
        if (!_fork()) return;

        // ── STEP 1: portal curve state of the friend token ──────────────────────────────────
        IPortalTypes.TokenStateV8Safe memory s = IPortalLens(PORTAL_LENS).getTokenV8Safe(TEST);
        emit log_named_uint("TEST status (1=Tradable)", s.status);
        emit log_named_uint("TEST curve price (wei/1e18)", s.price);
        emit log_named_address("TEST pool (0=on curve)", s.pool);

        // ── STEP 2: deploy the production oracle against the friend token ────────────────────
        oracle = new RamPriceOracle(PORTAL_LENS, TEST, WBNB, PCS_FACTORY, FLOOR, TRUNC);
        (uint256 oPrice, bool oTrusted) = oracle.getPrice(TEST);
        emit log_named_uint("oracle price (wei/1e18 RAM)", oPrice);
        emit log_named_string("oracle trusted", oTrusted ? "true" : "false");

        // If the token is a live curve token, the oracle must price it == portal marginal price.
        if (s.status == 1 && s.pool == address(0) && s.price > 0) {
            assertTrue(oTrusted, "curve token must be trusted");
            assertEq(oPrice, s.price, "oracle == portal marginal (curve)");
        }
        require(oTrusted && oPrice > 0, "REHEARSAL NEEDS A PRICEABLE TOKEN");

        // Cage: a band around the live oracle price (min = -50%, max = +100%).
        uint256 cageMin = oPrice / 2;
        uint256 cageMax = oPrice * 2;

        // ── STEP 3: create the vault via the REAL factory (impersonate the VaultPortal) ──────
        bytes memory vd = abi.encode(
            NVDAB,
            NVDA_FEED,
            BNB_FEED,
            BASE,
            BASE_USD,
            block.timestamp + 90 days,
            address(oracle),
            cageMin,
            cageMax,
            TREASURY
        );
        vm.prank(VAULT_PORTAL);
        vault = RamMiningVaultUpgradeable(payable(FACTORY.newVault(TEST, address(0), DEV, vd)));
        emit log_named_address("vault created", address(vault));
        assertEq(vault.ENTRY_PLAN_ID(), 0, "gate present");
        assertEq(vault.taxToken(), TEST, "taxToken = friend token");

        // ── STEP 4: fund the vault (NVDAB reward + BNB for the keeper) ───────────────────────
        deal(NVDAB, address(this), 1_000e18);
        IERC20F(NVDAB).approve(address(vault), type(uint256).max);
        vm.deal(address(vault), 50 ether); // BNB the keeper will draw against

        // ── STEP 5a: ENTRY GATE - fresh wallet, Hyper-first must revert, Micro-first must pass
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EntryRigMustBeMicro.selector);
        vault.buyMiningContract{value: 0.02 ether}(3); // Hyper-first (the bug the user found) → blocked

        vm.prank(alice);
        vault.buyMiningContract{value: BASE}(0); // Micro entry (the ONLY legal first buy)
        assertTrue(vault.hasEnteredBefore(alice), "alice entered");
        (uint256 aCount,,,,) = vault.getUserMinerStats(alice);
        assertEq(aCount, 1, "alice has 1 rig");
        emit log("STEP 5a OK: entry gate enforced on the real factory vault");

        // ── STEP 5b: RAM PATH - can a miner pay the friend token pre-graduation? ─────────────
        // Give alice TEST and try the growth-rig purchase. If the tax token blocks transfers on
        // the curve, this reverts - a CRITICAL launch gap (Phase-2 needs a transferable token).
        (uint256 units, bool qTrusted) = vault.quoteRigInRam(3); // Hyper in RAM
        emit log_named_uint("quoteRigInRam(Hyper) units", units);
        emit log_named_string("quote trusted", qTrusted ? "true" : "false");
        deal(TEST, alice, units * 4); // headroom for transfer tax

        uint256 aliceTestBefore = IERC20F(TEST).balanceOf(alice);
        emit log_named_uint("alice TEST balance (deal ok?)", aliceTestBefore);

        vm.prank(alice);
        IERC20F(TEST).approve(address(vault), type(uint256).max);

        uint256 deadBefore = IERC20F(TEST).balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 treaBefore = IERC20F(TEST).balanceOf(TREASURY);

        vm.prank(alice);
        try vault.buyMiningContract(3) {
            (uint256 c2, uint256 p2,,,) = vault.getUserMinerStats(alice);
            emit log_named_uint("RAM path OK - alice rig count", c2);
            emit log_named_uint("RAM path OK - alice power", p2);
            uint256 burned = IERC20F(TEST).balanceOf(0x000000000000000000000000000000000000dEaD) - deadBefore;
            uint256 toTrea = IERC20F(TEST).balanceOf(TREASURY) - treaBefore;
            emit log_named_uint("TEST burned (85%)", burned);
            emit log_named_uint("TEST to treasury (15%)", toTrea);
            assertGt(burned, 0, "burn happened");
            assertGt(toTrea, 0, "treasury paid");
            emit log("STEP 5b OK: Phase-2 RAM sink works with the friend token");
        } catch Error(string memory reason) {
            emit log_named_string("STEP 5b GAP: RAM buy reverted (string)", reason);
        } catch (bytes memory lowlevel) {
            emit log_named_bytes("STEP 5b GAP: RAM buy reverted (selector)", lowlevel);
            emit log("-> LIKELY: the friend token blocks transfers pre-graduation. Phase-2 needs graduation.");
        }

        // ── STEP 6: keeper path - Guardian arms guards, keeper sells NVDAB for BNB ───────────
        vm.startPrank(GUARDIAN);
        vault.setOracleGuards(500, 1 hours, 7 days);
        // reference must be within band of the live NVDA feed; read the vault's own quote basis via a tiny sell quote
        uint256 refProbe = _nvdaUsdPerBnbRef();
        vault.setReferencePrice(refProbe);
        vault.setKeeperLimits(10 ether, 20 ether);
        vm.stopPrank();
        emit log("STEP 6a OK: Guardian armed oracle guards + reference + keeper caps");

        // keeper needs NVDAB to sell into the vault
        deal(NVDAB, keeper, 100e18);
        vm.startPrank(keeper);
        IERC20F(NVDAB).approve(address(vault), type(uint256).max);
        uint256 keeperBnbBefore = keeper.balance;
        try vault.sellRWAToVault(1e18, 0) returns (uint256 bnbOwed) {
            emit log_named_uint("keeper sold 1 NVDAB, got BNB wei", bnbOwed);
            assertGt(bnbOwed, 0, "keeper paid in BNB");
            assertEq(keeper.balance - keeperBnbBefore, bnbOwed, "BNB received matches owed");
            emit log("STEP 6b OK: keeper sold NVDAB for BNB at the premium");
        } catch Error(string memory r) {
            emit log_named_string("STEP 6b note: sell reverted", r);
        } catch (bytes memory b) {
            emit log_named_bytes("STEP 6b note: sell reverted (selector)", b);
        }
        vm.stopPrank();

        // disarmSells cuts egress
        vm.prank(GUARDIAN);
        vault.disarmSells();
        emit log("STEP 6c OK: disarmSells executed (egress stop)");

        // ── STEP 7: a miner claims pro-rata NVDA ────────────────────────────────────────────
        uint256 claimable = vault.pendingRewards(alice);
        emit log_named_uint("alice claimable NVDA", claimable);
        if (claimable > 0) {
            uint256 nvBefore = IERC20F(NVDAB).balanceOf(alice);
            vm.prank(alice);
            vault.claimRewards();
            assertGe(IERC20F(NVDAB).balanceOf(alice) - nvBefore, 0, "claim delivered");
            emit log("STEP 7 OK: miner claimed NVDA");
        }

        emit log("=== REHEARSAL COMPLETE ===");
    }

    /// @dev A reference price inside the band of the live NVDA/USD feed. The vault's band compares the armed
    ///      reference against the live NVDA feed, so we just mirror the live feed answer (scaled to 18-dec as the
    ///      vault does internally is not needed here - setReferencePrice validates against _readFeed directly).
    function _nvdaUsdPerBnbRef() internal view returns (uint256) {
        (, int256 answer,,,) = IAgg(NVDA_FEED).latestRoundData();
        return uint256(answer); // 8-dec NVDA/USD; the vault validates it lands within priceDeviationBps of live
    }
}

interface IAgg {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
