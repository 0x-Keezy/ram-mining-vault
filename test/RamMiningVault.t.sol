// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
import {BadFeedDecimals, BadFeedPrice, NoMiners, NotAuthorized, NothingToClaim, OnlyGuardian, OnlyVaultPortal, OverFillCap, OverWindowCap, PremiumOutOfRange, PriceOutOfBand, ReferenceNotArmed, RigEndsTooSoon, SeasonEnded, Slippage, StaleFeed, StaleRound, StalenessTooLoose, TimelockNotElapsed, TooManyRigs} from "../src/RamMiningVault.sol";
import {VaultDataSchema, VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

/// @dev Mintable ERC20 standing in for tokenized NVIDIA (NVDAB) in deterministic tests.
///      Configurable decimals (NVDAB = 18, but we test 8↔18 normalization) + a toggle to revert transfers
///      (simulates the regulated reward token being paused / a recipient being non-compliant).
contract MockRewardToken is ERC20 {
    uint8 private immutable _dec;
    bool public revertTransfers;

    constructor(uint8 d) ERC20("Test NVIDIA", "tNVDA") {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRevertTransfers(bool v) external {
        revertTransfers = v;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        // allow mint (from == 0) so we can fund accounts even while "paused"
        if (from != address(0) && to != address(0)) {
            require(!revertTransfers, "token paused");
        }
    }
}

/// @dev Configurable Chainlink price feed mock (NVDA/USD and BNB/USD), 8 decimals.
contract MockPriceFeed {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _roundId;
    uint80 internal _answeredInRound;

    constructor(uint8 _decimals, int256 answer_) {
        decimals = _decimals;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
        _answeredInRound = 1;
    }

    /// @notice Set a fresh answer (also bumps updatedAt to now and advances the round).
    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId += 1;
        _answeredInRound = _roundId;
    }

    /// @notice Refresh updatedAt to now without changing the answer.
    function refresh() external {
        _updatedAt = block.timestamp;
        _roundId += 1;
        _answeredInRound = _roundId;
    }

    /// @notice Force a specific updatedAt (for staleness tests).
    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    /// @notice Force round ids (for answeredInRound < roundId tests).
    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}

/// @dev Mock IRamPriceOracle: settable price (BNB wei per 1e18 RAM) + trust flag + revert toggle.
contract MockRamOracle {
    uint256 public price;
    bool public trusted;
    bool public revertCalls;

    function set(uint256 p, bool t) external {
        price = p;
        trusted = t;
    }

    function setRevert(bool v) external {
        revertCalls = v;
    }

    function pokeAndGetPrice(address) external view returns (uint256, bool) {
        require(!revertCalls, "oracle down");
        return (price, trusted);
    }

    function getPrice(address) external view returns (uint256, bool) {
        require(!revertCalls, "oracle down");
        return (price, trusted);
    }
}

/// @dev Buyer contract whose receive() reverts — used to test the safe-refund path.
contract RevertingBuyer {
    function buy(RamMiningVaultUpgradeable v, uint256 plan) external payable {
        v.buyMiningContract{value: msg.value}(plan);
    }

    receive() external payable {
        revert("no refunds");
    }
}

/// @dev Fee-on-transfer reward token (1% fee burned on every non-mint transfer) — must-fix #5/#8: the vault must
///      credit + pay the keeper on the REAL received delta, not the nominal amount.
contract FeeRewardToken is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("Fee NVIDIA", "fNVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * FEE_BPS) / 10000;
        if (fee > 0) {
            super._transfer(from, address(0xdead), fee);
        }
        super._transfer(from, to, amount - fee);
    }
}

/// @dev Malicious keeper that tries to re-enter sellRWAToVault from its BNB receive() hook.
contract ReentrantKeeper {
    RamMiningVaultUpgradeable public vault;
    IERC20 public reward;
    uint256 public amt;
    bool public reentryAttempted;
    bool public reentryReverted;

    constructor(RamMiningVaultUpgradeable _vault, IERC20 _reward) {
        vault = _vault;
        reward = _reward;
    }

    function attack(uint256 _amt) external {
        amt = _amt;
        reward.approve(address(vault), type(uint256).max);
        vault.sellRWAToVault(_amt, 0);
    }

    receive() external payable {
        // attempt to re-enter while the vault is paying us; the nonReentrant guard must block it
        if (!reentryAttempted) {
            reentryAttempted = true;
            try vault.sellRWAToVault(amt, 0) {
                reentryReverted = false;
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract RamMiningVaultTest is Test {
    address constant BNB_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant RAM_TOKEN = address(0x4A11); // taxToken placeholder (not held by vault)

    // oracle prices (8 dec): NVDA = $130, BNB = $600
    int256 constant NVDA_USD = 130e8;
    int256 constant BNB_USD = 600e8;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xCAFE);

    MockRewardToken reward;
    MockRewardToken ram; // the RAM tax token (Phase-2 sink currency)
    MockRamOracle ramOracle;
    MockPriceFeed nvdaFeed;
    MockPriceFeed bnbFeed;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;
    uint256 seasonEnd;

    // RAM priced at 2e12 wei BNB per 1e18 RAM (1 RAM = 0.000002 BNB); cage [1e12, 4e12] around it
    uint256 constant RAM_BNB_PRICE = 2e12;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days); // start on a clean bucket boundary, away from bucket 0
        reward = new MockRewardToken(18);
        ram = new MockRewardToken(18);
        ramOracle = new MockRamOracle();
        nvdaFeed = new MockPriceFeed(8, NVDA_USD);
        bnbFeed = new MockPriceFeed(8, BNB_USD);
        factory = new RamMiningBeaconFactory();

        seasonEnd = block.timestamp + 60 days;
        // Phase-2 armed at creation via vaultData (launcher-armed path): oracle + cage in the last 3 fields
        ramOracle.set(RAM_BNB_PRICE, true);
        bytes memory vaultData = abi.encode(
            address(reward),
            address(nvdaFeed),
            address(bnbFeed),
            basePrice,
            seasonEnd,
            address(ramOracle),
            RAM_BNB_PRICE / 2,
            RAM_BNB_PRICE * 2
        );

        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        address vaultAddress = factory.newVault(address(ram), address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vaultData);
        vault = RamMiningVaultUpgradeable(payable(vaultAddress));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        reward.mint(address(this), 10_000_000 ether); // for donateReward injections
        reward.approve(address(vault), type(uint256).max);
        ram.mint(alice, 1e27);
        ram.mint(bob, 1e27);
        vm.prank(alice);
        ram.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        ram.approve(address(vault), type(uint256).max);
    }

    // ── helpers ─────────────────────────────────────────────────────────

    function _freshFeeds() internal {
        nvdaFeed.refresh();
        bnbFeed.refresh();
    }

    /// @dev Arm the deviation band reference at the current (fresh) feed price.
    function _armReference() internal {
        _freshFeeds();
        vm.prank(GUARDIAN);
        vault.setReferencePrice(uint256(NVDA_USD));
    }

    /// @dev Arm the keeper: reference price (required) + egress caps. Sells are disabled until both are set.
    function _armKeeperWithLimits(uint256 perFill, uint256 perWindow) internal {
        _armReference();
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(perFill, perWindow);
    }

    function _armKeeper() internal {
        _armKeeperWithLimits(100 ether, 100 ether);
    }

    /// @dev Deploy a fresh vault pointed at an arbitrary reward token (8↔18 / fee-on-transfer / reentrancy tests).
    function _deployVault(address rewardTok) internal returns (RamMiningVaultUpgradeable v) {
        bytes memory vd =
            abi.encode(rewardTok, address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        v = RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vd)));
    }

    function _inject(uint256 amount) internal {
        vault.donateReward(amount);
    }

    function _buy(address who, uint256 plan) internal {
        (uint256 price,,,) = vault.getPlan(plan);
        vm.prank(who);
        vault.buyMiningContract{value: price}(plan);
    }

    /// @dev Phase-2: buy a growth rig (#2+) paying RAM (no BNB attached).
    function _buyRam(address who, uint256 plan) internal {
        vm.prank(who);
        vault.buyMiningContract(plan);
    }

    /// @dev keeper sells `amount` reward into the vault; vault must hold enough BNB.
    function _sell(uint256 amount, uint256 minBnbOut) internal returns (uint256 bnbOwed) {
        reward.mint(keeper, amount);
        vm.startPrank(keeper);
        reward.approve(address(vault), amount);
        bnbOwed = vault.sellRWAToVault(amount, minBnbOut);
        vm.stopPrank();
    }

    // ── schema / config ────────────────────────────────────────────────

    function testFactorySchema() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 8);
        assertEq(s.fields[0].name, "rewardToken");
        assertEq(s.fields[1].name, "rewardPriceFeed");
        assertEq(s.fields[2].name, "bnbPriceFeed");
        assertEq(s.fields[3].name, "basePriceWei");
        assertEq(s.fields[4].name, "seasonEnd");
        assertEq(s.fields[5].name, "ramPriceOracle");
        assertEq(s.fields[6].name, "ramCageMin");
        assertEq(s.fields[7].name, "ramCageMax");
        assertFalse(s.isArray);
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(RAM_TOKEN));
    }

    /// Rule 002 / reference test: newVault must revert for any caller other than the VaultPortal.
    function testFactoryRejectsNonVaultPortalCaller() public {
        bytes memory vd =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.expectRevert(OnlyVaultPortal.selector);
        factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vd); // not pranked as the portal
    }

    /// Flap Post-Audit Step 0: even when called by the VaultPortal, only the authorized dev wallet may
    /// launch a vault through this factory. Any other creator is rejected at creation.
    function testFactoryRejectsNonDevCreator() public {
        assertEq(factory.DEV_ADDRESS(), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1);
        bytes memory vd =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        vm.expectRevert(NotAuthorized.selector);
        factory.newVault(RAM_TOKEN, address(0), address(0xBAD), vd);
    }

    /// description() must reflect state (no rigs yet → mining), per the integration-test guide.
    function testDescriptionChangesWithState() public {
        string memory before = vault.description();
        _buy(alice, 0);
        string memory after_ = vault.description();
        assertTrue(keccak256(bytes(before)) != keccak256(bytes(after_)), "description() should change with state");
    }

    function testVaultSchema() public view {
        // v3 TEST BUILD: schema intentionally minimal (bespoke UI in use; Flap Step 2 recipe).
        // Restoring a full schema for production is a P4 decision with Flap.
        VaultUISchema memory ui = vault.vaultUISchema();
        assertEq(ui.vaultType, "RamMiningVault");
        assertEq(ui.methods.length, 0);
    }

    function testInitConfig() public view {
        assertEq(vault.taxToken(), address(ram));
        assertEq(vault.rewardToken(), address(reward));
        assertEq(vault.rewardPriceFeed(), address(nvdaFeed));
        assertEq(vault.bnbPriceFeed(), address(bnbFeed));
        assertEq(vault.basePriceWei(), basePrice);
        assertEq(vault.seasonEnd(), seasonEnd);
        assertEq(vault.rewardTokenDecimals(), 18);
        assertEq(vault.keeperPremiumBps(), 10300); // default 1.03 (centre of Flap's 1.02–1.04 band)
        // weekend-friendly staleness defaults (Flap #8): NVDA/USD generous (7d), BNB/USD tight (2h)
        assertEq(vault.rewardFeedMaxStale(), 7 days);
        assertEq(vault.bnbFeedMaxStale(), 2 hours);
        // sells disabled until the guardian arms the egress caps
        assertEq(vault.maxBnbOutPerFill(), 0);
        assertEq(vault.maxBnbOutPerWindow(), 0);
    }

    // ── core: buy + real-yield claim (donate path) ─────────────────────

    function testBuyAndClaimShareBased() public {
        _buy(alice, 0); // 10 power
        _inject(100 ether); // alice is the only power -> gets all
        assertApproxEqAbs(vault.pendingRewards(alice), 100 ether, 100);

        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, 100 ether, 100);
        assertApproxEqAbs(reward.balanceOf(alice), 100 ether, 100);
        assertEq(vault.pendingRewards(alice), 0);
    }

    function testProportionalSplit() public {
        _buy(alice, 0); // 10 power
        _buy(bob, 1); // Core: 28 power (v3 concave table) -> total 38
        _inject(38 ether);
        assertApproxEqAbs(vault.pendingRewards(alice), 10 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 28 ether, 1e6);
    }

    function testRewardWhileNoPowerGoesToFirstMiner() public {
        _inject(30 ether);
        assertEq(vault.rewardUndistributed(), 30 ether);
        assertEq(vault.pendingRewards(alice), 0);

        _buy(alice, 0);
        _inject(0.000000000001 ether);
        assertApproxEqAbs(vault.pendingRewards(alice), 30 ether, 1e9);
    }

    function testClaimRewardsToOtherAddress() public {
        _buy(alice, 0);
        _inject(10 ether);
        vm.prank(alice);
        uint256 got = vault.claimRewardsTo(bob);
        assertApproxEqAbs(got, 10 ether, 100);
        assertApproxEqAbs(reward.balanceOf(bob), 10 ether, 100);
        assertEq(reward.balanceOf(alice), 0);
    }

    // ── per-rig expiry (lazy buckets) ──────────────────────────────────

    function testExpiryFreezesRigButActiveKeepsEarning() public {
        // v3: all rigs live RIG_LIFE (60d) capped by the season, so per-plan early expiry is gone. The freeze
        // property still holds at season end: pending is frozen at the expiry snapshot and never grows after.
        _buy(alice, 0); // Micro 10 power, expires with the season (60d)
        _inject(50 ether); // alice is the only miner -> all 50
        assertApproxEqAbs(vault.pendingRewards(alice), 50 ether, 1e6);

        vm.warp(seasonEnd + 1); // rig expired with the season
        _inject(40 ether); // no active power -> buffered as rewardUndistributed, nothing accrues to alice
        assertApproxEqAbs(vault.pendingRewards(alice), 50 ether, 1e6); // frozen at expiry

        (,, uint256 power,,,,) = vault.getVaultMiningStats();
        assertEq(power, 0);
        assertEq(vault.rewardUndistributed(), 40 ether);
    }

    // ── keeper / RFQ acquisition ───────────────────────────────────────

    function testQuoteRWAToVault() public view {
        // 1 NVDA @ $130 / $600 BNB = 0.21666.. BNB market, +3% default premium
        uint256 owed = vault.quoteRWAToVault(1e18);
        uint256 expectedMarket = (1e18 * uint256(NVDA_USD)) / uint256(BNB_USD);
        uint256 expected = (expectedMarket * 10300) / 10000;
        assertEq(owed, expected);
    }

    function testQuoteDecimals8Equals18() public {
        // a fresh 8-decimal reward token vault should quote the SAME BNB for "1 token" as the 18-dec one
        MockRewardToken reward8 = new MockRewardToken(8);
        bytes memory vaultData =
            abi.encode(address(reward8), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable v8 =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vaultData)));
        assertEq(v8.rewardTokenDecimals(), 8);

        uint256 owed8 = v8.quoteRWAToVault(1e8); // 1 token in 8 dec
        uint256 owed18 = vault.quoteRWAToVault(1e18); // 1 token in 18 dec
        assertEq(owed8, owed18);
    }

    function testSellHappyPathDistributesByPower() public {
        _buy(alice, 0); // 10 power, only miner
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        uint256 amount = 1e18;
        uint256 quoted = vault.quoteRWAToVault(amount);
        uint256 keeperBalBefore = keeper.balance;

        uint256 owed = _sell(amount, 0);
        assertEq(owed, quoted);
        // keeper received BNB, vault received reward, alice (sole miner) credited
        assertEq(keeper.balance, keeperBalBefore + quoted);
        assertEq(reward.balanceOf(address(vault)), amount);
        assertApproxEqAbs(vault.pendingRewards(alice), amount, 100);
        assertEq(vault.lastFillTimestamp(), block.timestamp);
        assertEq(vault.totalBnbPaidToKeepers(), quoted);
    }

    function testSellRevertsWithoutMiners() public {
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(NoMiners.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellMinBnbOutSlippage() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteRWAToVault(1e18);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(Slippage.selector);
        vault.sellRWAToVault(1e18, quoted + 1); // demand more than the quote
        vm.stopPrank();
    }

    function testSellOverPerFillCapReverts() public {
        _buy(alice, 0);
        _armReference();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteRWAToVault(1e18);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(quoted - 1, 100 ether); // per-fill cap below the quote

        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(OverFillCap.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellWindowRateLimit() public {
        _buy(alice, 1); // Core rig (7 days) so the miner survives the 1-day window warp below
        _armReference();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteRWAToVault(1e18);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(quoted * 2, quoted); // window allows exactly ONE fill of 1e18

        _sell(1e18, 0); // first fill OK

        // second fill within the same window breaches the window cap
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(OverWindowCap.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();

        // after the window rolls over, a fill is allowed again
        vm.warp(block.timestamp + vault.WINDOW());
        _freshFeeds();
        uint256 owed = _sell(1e18, 0);
        assertEq(owed, quoted);
    }

    /// Documents the FIXED/TUMBLING window boundary: ~2x maxBnbOutPerWindow can egress straddling a boundary
    /// (full cap just before the reset + full cap just after). NOT a drain (value-for-value), but the guardian
    /// must size maxBnbOutPerWindow accordingly. See _consumeWindow.
    function testWindowBoundaryAllowsDoubleEgressBurst() public {
        _buy(alice, 1); // Core rig (7 days) survives the warp
        _armReference();
        vm.deal(address(vault), 10 ether);
        uint256 quoted = vault.quoteRWAToVault(1e18);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(quoted * 2, quoted); // per-window cap = exactly one 1e18 fill

        // fill the full cap at the LAST instant of the current window
        vm.warp(vault.windowStart() + vault.WINDOW() - 1);
        _freshFeeds();
        _sell(1e18, 0);

        // cross the boundary by 1 second → tumbling reset grants a FRESH full cap → second full fill ~1s later
        vm.warp(block.timestamp + 1);
        _freshFeeds();
        _sell(1e18, 0);

        // ~2x the nominal per-window cap egressed within ~1 second — the documented boundary burst
        assertEq(vault.totalBnbPaidToKeepers(), 2 * quoted, "tumbling window allows ~2x at the boundary");
    }

    /// @dev Flap pre-audit #2: disarmSells() atomically zeros BOTH egress caps AND the deviation reference in one
    ///      call, and a subsequent keeper sell fails-closed. Removes the "referencePrice==0 while caps armed" window.
    function testDisarmSellsAtomicAndFailsClosed() public {
        _buy(alice, 1); // Core rig
        vm.deal(address(vault), 10 ether);
        _armKeeperWithLimits(100 ether, 100 ether);

        // sells work while armed
        _freshFeeds();
        uint256 paid = _sell(1e18, 0);
        assertGt(paid, 0, "armed sell should pay BNB");

        // guardian disarms in ONE atomic call
        vm.prank(GUARDIAN);
        vault.disarmSells();
        assertEq(vault.maxBnbOutPerFill(), 0, "per-fill cap zeroed");
        assertEq(vault.maxBnbOutPerWindow(), 0, "per-window cap zeroed");
        assertEq(vault.referencePrice(), 0, "reference disarmed");

        // a subsequent sell fails-closed (per-fill cap == 0)
        _freshFeeds();
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(OverFillCap.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    /// @dev disarmSells() is guardian-only.
    function testDisarmSellsOnlyGuardian() public {
        vm.expectRevert();
        vault.disarmSells();
    }

    function testSellDeviationBandReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // arm the band at the current price, then move the feed > 5% away (default band)
        vm.prank(GUARDIAN);
        vault.setReferencePrice(uint256(NVDA_USD));
        nvdaFeed.setAnswer(140e8); // +7.7% vs reference 130

        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(PriceOutOfBand.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellWithinDeviationBandOk() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        vm.prank(GUARDIAN);
        vault.setReferencePrice(uint256(NVDA_USD));
        nvdaFeed.setAnswer(131e8); // +0.77% within the 5% band

        uint256 owed = _sell(1e18, 0);
        assertGt(owed, 0);
    }

    /// Flap #8 (weekend continuous operation): with the generous 7d NVDA/USD staleness, a feed that is merely
    /// frozen over the weekend (e.g. 2 days old) does NOT revert — the keeper fill keeps operating at the last
    /// print. This INVERTS the old "weekend-freeze = de-facto pause" behaviour, per Flap's onboarding guidance.
    function testWeekendStaleFeedStillOperates() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // NVDA/USD 2 days old (frozen over a weekend) but within the 7d bound; BNB/USD kept fresh (24/7).
        // The reference must sit on the same (frozen) feed value so the deviation band passes.
        nvdaFeed.setUpdatedAt(block.timestamp - 2 days);
        uint256 owed = _sell(1e18, 0); // fill OPERATES (no pause) — Flap #8
        assertGt(owed, 0);
        assertGt(vault.pendingRewards(alice), 0);
    }

    /// Dead-feed safety wall: a genuinely dead NVDA/USD feed (older than the 7d bound) still makes the sell
    /// REVERT — the generous weekend staleness never tolerates a feed that has actually stopped printing.
    function testDeadRewardFeedReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // NVDA/USD older than rewardFeedMaxStale (default 7d) -> revert (real dead-feed wall)
        nvdaFeed.setUpdatedAt(block.timestamp - 8 days);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(StaleFeed.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellStaleBnbFeedReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // BNB/USD older than bnbFeedMaxStale (default 2h); reward feed kept fresh
        bnbFeed.setUpdatedAt(block.timestamp - 3 hours);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(StaleFeed.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellBadFeedAnswerReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        nvdaFeed.setAnswer(0); // non-positive price
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(BadFeedPrice.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellAnsweredInRoundStaleReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        nvdaFeed.setRound(5, 4); // answeredInRound < roundId
        nvdaFeed.setUpdatedAt(block.timestamp);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(StaleRound.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    /// Flap no-pause model: there is NO pause anywhere. The Guardian has NO selector to pause acquisition, pause
    /// the vault, or drain via an emergency hatch — recovery is the Guardian-only beacon upgrade (factory). This
    /// asserts every removed privileged hatch/pause selector is genuinely absent (low-level call returns false).
    function testNoPauseOrEmergencyHatchSelectorsExist() public {
        // pause / acquisition-pause selectors are gone
        (bool a,) = address(vault).call(abi.encodeWithSignature("pauseVault()"));
        (bool b,) = address(vault).call(abi.encodeWithSignature("pauseAcquisition()"));
        (bool c,) = address(vault).call(abi.encodeWithSignature("resumeAcquisition()"));
        // emergency-withdraw / rescue hatches are gone (Rule 009 proxy exemption)
        (bool d,) = address(vault).call(abi.encodeWithSignature("emergencyWithdrawNative(address)", GUARDIAN));
        (bool e,) = address(vault).call(abi.encodeWithSignature("emergencyWithdrawToken(address,address)", address(reward), GUARDIAN));
        (bool f,) = address(vault).call(abi.encodeWithSignature("emergencyRescueReward(address)", GUARDIAN));
        (bool g,) = address(vault).call(abi.encodeWithSignature("scheduleEmergencyRescue()"));
        (bool h,) = address(vault).call(abi.encodeWithSignature("setPauseManager(address)", GUARDIAN));
        assertTrue(!a && !b && !c && !d && !e && !f && !g && !h, "no pause/hatch selector may exist");
    }

    /// Claims and buys are ALWAYS available (no pause can ever gate them).
    function testClaimAndBuyAlwaysAvailable() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);
        _sell(1e18, 0);

        uint256 pending = vault.pendingRewards(alice);
        assertGt(pending, 0);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, pending, 100);

        // buying a new rig also always works (no pause)
        _buy(bob, 0);
        (uint256 count,,,,) = vault.getUserMinerStats(bob);
        assertEq(count, 1);
    }

    function testSellDisabledByDefault() public {
        // caps are 0 at init -> any sell is over the per-fill cap
        _buy(alice, 0);
        _freshFeeds();
        vm.deal(address(vault), 10 ether);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(OverFillCap.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSetKeeperPremiumOnlyGuardianAndClamped() public {
        // setKeeperPremium is gated by the Flap template's guard (VaultBaseV2), whose message we don't touch
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.setKeeperPremium(10100);

        vm.prank(GUARDIAN);
        vm.expectRevert(PremiumOutOfRange.selector);
        vault.setKeeperPremium(9999); // below MIN

        vm.prank(GUARDIAN);
        vm.expectRevert(PremiumOutOfRange.selector);
        vault.setKeeperPremium(10401); // above MAX (10400)

        vm.prank(GUARDIAN);
        vault.setKeeperPremium(10350); // within [10200, 10400]
        assertEq(vault.keeperPremiumBps(), 10350);
    }

    // ── claim safety: reward token that reverts the transfer ───────────

    function testClaimRevertsCleanlyWhenRewardPaused() public {
        _buy(alice, 0); // 10
        _buy(bob, 1); // 40
        _inject(50 ether); // alice 10, bob 40 (transfers still allowed: mint path)

        uint256 alicePending = vault.pendingRewards(alice);
        uint256 bobPending = vault.pendingRewards(bob);
        assertGt(alicePending, 0);
        assertGt(bobPending, 0);

        // reward token gets paused (transfers revert)
        reward.setRevertTransfers(true);

        vm.prank(alice);
        vm.expectRevert(bytes("token paused"));
        vault.claimRewards();

        // accounting intact: nothing claimed, bob's pending untouched
        assertEq(vault.totalRewardClaimed(), 0);
        assertEq(vault.pendingRewards(alice), alicePending);
        assertEq(vault.pendingRewards(bob), bobPending);

        // once unpaused, alice can claim normally
        reward.setRevertTransfers(false);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, alicePending, 100);
    }

    // ── oracle-guard staleness ceilings (T5: dead-feed wall + tight BNB) ──

    /// setOracleGuards clamps each staleness to its ceiling: NVDA/USD ≤ 30d (dead-feed wall), BNB/USD ≤ 1d (24/7).
    function testSetOracleGuardsCeilings() public {
        // reward-feed staleness above MAX_REWARD_FEED_STALE (30d) -> revert
        vm.prank(GUARDIAN);
        vm.expectRevert(StalenessTooLoose.selector);
        vault.setOracleGuards(200, 2 hours, 31 days);

        // BNB-feed staleness above MAX_BNB_FEED_STALE (1d) -> revert
        vm.prank(GUARDIAN);
        vm.expectRevert(StalenessTooLoose.selector);
        vault.setOracleGuards(200, 2 days, 7 days);

        // valid: NVDA 7d, BNB 6h
        vm.prank(GUARDIAN);
        vault.setOracleGuards(200, 6 hours, 7 days);
        assertEq(vault.rewardFeedMaxStale(), 7 days);
        assertEq(vault.bnbFeedMaxStale(), 6 hours);

        // a guardian can tighten toward Flap's 24/7 feed (e.g. 12h) once it is wired
        vm.prank(GUARDIAN);
        vault.setOracleGuards(200, 2 hours, 12 hours);
        assertEq(vault.rewardFeedMaxStale(), 12 hours);
    }

    // ── edges / audit-fix coverage ─────────────────────────────────────

    function testMaxRigsCap() public {
        _buy(alice, 0); // rig #1: BNB entry
        for (uint256 i = 0; i < 15; i++) {
            _buyRam(alice, 0); // rigs #2..#16: RAM path
        }
        vm.prank(alice);
        vm.expectRevert(TooManyRigs.selector);
        vault.buyMiningContract(0);
    }

    function testRefundExcess() public {
        uint256 before = alice.balance;
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vault.buyMiningContract{value: price + 1 ether}(0);
        assertEq(alice.balance, before - price);
    }

    function testRefundRevertingBuyerReverts() public {
        RevertingBuyer rb = new RevertingBuyer();
        vm.deal(address(rb), 10 ether);
        (uint256 price,,,) = vault.getPlan(0);
        vm.expectRevert();
        rb.buy{value: price + 1 ether}(vault, 0);
    }

    function testBuyAfterSeasonEndReverts() public {
        vm.warp(seasonEnd + 1);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(SeasonEnded.selector);
        vault.buyMiningContract{value: price}(0);
    }

    // ── adversarial gate: blockers #1, #4, #5, #7, #9 ──────────────────

    /// blocker #1: a rig whose endBucket lands in the already-settled (last) bucket must be rejected, not bricked.
    function testLastBucketBrickRejected() public {
        // short season so a rig can be capped into the current bucket near seasonEnd
        uint256 shortSeason = block.timestamp + 36 hours; // 1.5 days (>= block.timestamp + 1 day)
        bytes memory vd =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, shortSeason, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable v =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vd)));

        (uint256 price,,,) = v.getPlan(0);
        vm.deal(alice, 1 ether);

        // normal buy now: rig ends in a FUTURE bucket -> OK
        vm.prank(alice);
        v.buyMiningContract{value: price}(0);

        // warp into the season-end bucket: a new rig's end caps to seasonEnd in the already-settled bucket -> reject
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vm.expectRevert(RigEndsTooSoon.selector);
        v.buyMiningContract{value: price}(0);
    }

    /// must-fix #5/#8: with a fee-on-transfer reward token the vault credits + pays on the REAL received delta.
    function testFeeOnTransferUsesRealDelta() public {
        FeeRewardToken fee = new FeeRewardToken();
        RamMiningVaultUpgradeable v = _deployVault(address(fee));

        vm.deal(alice, 1 ether);
        (uint256 price,,,) = v.getPlan(0);
        vm.prank(alice);
        v.buyMiningContract{value: price}(0);

        _freshFeeds();
        vm.prank(GUARDIAN);
        v.setReferencePrice(uint256(NVDA_USD));
        vm.prank(GUARDIAN);
        v.setKeeperLimits(100 ether, 100 ether);
        vm.deal(address(v), 10 ether);

        uint256 amount = 1e18;
        uint256 received = amount - (amount * fee.FEE_BPS()) / 10000; // 0.99e18
        uint256 expectedOwed = v.quoteRWAToVault(received);

        fee.mint(keeper, amount);
        uint256 keeperBnbBefore = keeper.balance;
        vm.startPrank(keeper);
        fee.approve(address(v), amount);
        uint256 owed = v.sellRWAToVault(amount, 0);
        vm.stopPrank();

        assertEq(owed, expectedOwed, "paid on received delta");
        assertEq(keeper.balance, keeperBnbBefore + expectedOwed);
        assertEq(fee.balanceOf(address(v)), received, "vault holds the real delta");
        assertApproxEqAbs(v.pendingRewards(alice), received, 100);
        // nominal-based payout would have been strictly larger -> confirms we did NOT overpay
        assertGt(v.quoteRWAToVault(amount), expectedOwed);
    }

    /// must-fix #5/#8 reentrancy wall: a keeper that re-enters from its BNB receive() is blocked by nonReentrant.
    function testReentrancyGuardBlocksReenter() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        ReentrantKeeper atk = new ReentrantKeeper(vault, IERC20(address(reward)));
        reward.mint(address(atk), 5e18);
        uint256 amount = 1e18;
        uint256 quoted = vault.quoteRWAToVault(amount);

        atk.attack(amount);

        // the reentrant attempt happened AND was reverted by the guard; only ONE legitimate payout went out
        assertTrue(atk.reentryAttempted(), "attacker tried to re-enter");
        assertTrue(atk.reentryReverted(), "nonReentrant blocked the re-enter");
        assertEq(vault.totalBnbPaidToKeepers(), quoted, "exactly one payout");
        assertEq(address(atk).balance, quoted);
    }

    /// should-fix #7: feeds must be 8-decimal (quote math assumption) — both at setPriceFeeds and at initialize.
    function testSetPriceFeedsRejectsNon8Decimals() public {
        MockPriceFeed bad = new MockPriceFeed(18, 100e8);
        vm.prank(GUARDIAN);
        vm.expectRevert(BadFeedDecimals.selector);
        vault.setPriceFeeds(address(bad), address(bnbFeed));

        vm.prank(GUARDIAN);
        vm.expectRevert(BadFeedDecimals.selector);
        vault.setPriceFeeds(address(nvdaFeed), address(bad));
    }

    function testInitRejectsNon8DecimalFeed() public {
        MockPriceFeed bad = new MockPriceFeed(6, 100e8);
        bytes memory vd =
            abi.encode(address(reward), address(bad), address(bnbFeed), basePrice, seasonEnd, address(0), 0, 0);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        vm.expectRevert(BadFeedDecimals.selector);
        factory.newVault(RAM_TOKEN, address(0), 0x8216fCD8a714B82Ee9d60793F551957D9abc1CA1, vd);
    }

    /// should-fix #9: changing feeds disarms the deviation band (referencePrice -> 0).
    function testSetPriceFeedsDisarmsReference() public {
        _armReference();
        assertEq(vault.referencePrice(), uint256(NVDA_USD));
        vm.prank(GUARDIAN);
        vault.setPriceFeeds(address(nvdaFeed), address(bnbFeed));
        assertEq(vault.referencePrice(), 0);
    }

    /// blocker #4b: enabling egress caps requires the deviation band to be armed first.
    function testSetKeeperLimitsRequiresReference() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(ReferenceNotArmed.selector);
        vault.setKeeperLimits(1 ether, 1 ether);

        _armReference();
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(1 ether, 1 ether);
        assertEq(vault.maxBnbOutPerFill(), 1 ether);

        // disabling (0/0) is always allowed
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(0, 0);
    }

    /// MEDIUM regression: the egress⟹band invariant is enforced on EVERY sell, not only at setKeeperLimits.
    /// Disarming the reference while caps stay armed must block the next sell until it is re-armed.
    function testBandInvariantEnforcedOnEverySell() public {
        _buy(alice, 0);
        _armKeeper(); // arms reference + caps (100/100)
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // a sell works while the band is armed
        _sell(1e18, 0);
        assertGt(vault.pendingRewards(alice), 0);

        // disarm the band (caps stay armed) -> the NEXT sell must revert (invariant enforced at sell time)
        vm.prank(GUARDIAN);
        vault.setReferencePrice(0);
        _freshFeeds();
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(ReferenceNotArmed.selector);
        vault.sellRWAToVault(1e18, 0);
        vm.stopPrank();

        // re-arming the reference restores sells
        _armReference();
        assertGt(_sell(1e18, 0), 0);
    }

    // ── factory upgrade timelock + lock (recovery = Guardian-only upgrade) ──

    function testUpgradeTimelock() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();

        vm.prank(GUARDIAN);
        factory.scheduleUpgrade(address(newImpl));

        vm.prank(GUARDIAN);
        vm.expectRevert(TimelockNotElapsed.selector);
        factory.executeUpgrade();

        vm.warp(block.timestamp + factory.UPGRADE_DELAY());
        vm.prank(GUARDIAN);
        factory.executeUpgrade();
        assertEq(factory.beaconImplementation(), address(newImpl));
    }

    function testScheduleUpgradeOnlyGuardian() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();
        vm.expectRevert(OnlyGuardian.selector);
        factory.scheduleUpgrade(address(newImpl));
    }

    /// Rule 009 (proxy): upgrade authority is Guardian-only — the Guardian can commit to immutability via lock.
    function testGuardianCanLockVaultUpgrades() public {
        assertFalse(factory.isVaultUpgradesLocked());
        vm.prank(GUARDIAN);
        factory.lockVaultUpgrades();
        assertTrue(factory.isVaultUpgradesLocked());

        // after locking, even the Guardian can no longer execute an upgrade (beacon ownership renounced)
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();
        vm.prank(GUARDIAN);
        factory.scheduleUpgrade(address(newImpl));
        vm.warp(block.timestamp + factory.UPGRADE_DELAY());
        vm.prank(GUARDIAN);
        vm.expectRevert(); // UpgradeableBeacon: caller is not the owner (ownership renounced)
        factory.executeUpgrade();
    }

    function testNonGuardianCannotLockVaultUpgrades() public {
        vm.expectRevert(OnlyGuardian.selector);
        factory.lockVaultUpgrades();
        assertFalse(factory.isVaultUpgradesLocked());
    }

    // ── invariants ─────────────────────────────────────────────────────

    function testNoDoubleClaim() public {
        _buy(alice, 0);
        _inject(10 ether);
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimRewards();
    }

    function testInvariantClaimedLeqDistributed() public {
        _buy(alice, 1); // 40
        _buy(bob, 2); // 130
        _inject(100 ether);
        vm.warp(block.timestamp + 1 days);
        _inject(50 ether);

        vm.prank(alice);
        vault.claimRewards();
        vm.warp(block.timestamp + 2 days);
        _inject(33 ether);
        vm.prank(bob);
        vault.claimRewards();

        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
        uint256 outstanding = vault.pendingRewards(alice) + vault.pendingRewards(bob);
        assertGe(reward.balanceOf(address(vault)) + 1e6, outstanding);
    }

    function testInvariantClaimedLeqDistributedWithKeeperFills() public {
        _buy(alice, 1); // 40
        _buy(bob, 2); // 130
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 50 ether);

        _sell(5e18, 0);
        vm.warp(block.timestamp + 1 days);
        _freshFeeds();
        _sell(3e18, 0);

        vm.prank(alice);
        vault.claimRewards();
        vm.prank(bob);
        vault.claimRewards();

        assertLe(vault.totalRewardClaimed(), vault.totalRewardDistributed());
    }

    function testGetMiningContractView() public {
        _buy(alice, 2); // Mega: 72 power (v3 concave table), RIG_LIFE
        (uint256 id, uint256 planId, uint256 power,,,, uint256 pending, bool active) =
            vault.getMiningContract(alice, 0);
        assertEq(id, 1);
        assertEq(planId, 2);
        assertEq(power, 72);
        assertEq(pending, 0);
        assertTrue(active);
    }

    // S4 (Flap rule 005/006): receive() must stay well under the 1,000,000 gas budget.
    function testReceiveGasUnder1M() public {
        vm.deal(address(this), 2 ether);
        uint256 g = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 used = g - gasleft();
        assertTrue(ok, "receive failed");
        assertLe(used, 1_000_000, "receive() must stay under 1M gas (Flap rule 005)");
    }

    receive() external payable {}
}
