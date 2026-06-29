// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {RamMiningBeaconFactory, RamMiningVaultUpgradeable} from "../src/RamMiningVault.sol";
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

/// @dev Buyer contract whose receive() reverts — used to test the safe-refund path.
contract RevertingBuyer {
    function buy(RamMiningVaultUpgradeable v, uint256 plan) external payable {
        v.buyMiningContract{value: msg.value}(plan);
    }

    receive() external payable {
        revert("no refunds");
    }
}

/// @dev Configurable on-chain pause oracle for the reward token (blocker #3 rescue gate).
contract MockPauseManager {
    bool public paused;

    function setPaused(bool v) external {
        paused = v;
    }

    function isTokenPaused(address) external view returns (bool) {
        return paused;
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

/// @dev Malicious keeper that tries to re-enter sellRewardToVault from its BNB receive() hook.
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
        vault.sellRewardToVault(_amt, 0);
    }

    receive() external payable {
        // attempt to re-enter while the vault is paying us; the nonReentrant guard must block it
        if (!reentryAttempted) {
            reentryAttempted = true;
            try vault.sellRewardToVault(amt, 0) {
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
    MockPriceFeed nvdaFeed;
    MockPriceFeed bnbFeed;
    RamMiningBeaconFactory factory;
    RamMiningVaultUpgradeable vault;

    uint256 basePrice = 0.001 ether;
    uint256 seasonEnd;

    function setUp() public {
        vm.chainId(97);
        vm.warp(10 days); // start on a clean bucket boundary, away from bucket 0
        reward = new MockRewardToken(18);
        nvdaFeed = new MockPriceFeed(8, NVDA_USD);
        bnbFeed = new MockPriceFeed(8, BNB_USD);
        factory = new RamMiningBeaconFactory();

        seasonEnd = block.timestamp + 60 days;
        bytes memory vaultData =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd);

        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        address vaultAddress = factory.newVault(RAM_TOKEN, address(0), address(this), vaultData);
        vault = RamMiningVaultUpgradeable(payable(vaultAddress));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        reward.mint(address(this), 10_000_000 ether); // for donateReward injections
        reward.approve(address(vault), type(uint256).max);
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
        bytes memory vd = abi.encode(rewardTok, address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        v = RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vd)));
    }

    function _inject(uint256 amount) internal {
        vault.donateReward(amount);
    }

    function _buy(address who, uint256 plan) internal {
        (uint256 price,,,) = vault.getPlan(plan);
        vm.prank(who);
        vault.buyMiningContract{value: price}(plan);
    }

    /// @dev keeper sells `amount` reward into the vault; vault must hold enough BNB.
    function _sell(uint256 amount, uint256 minBnbOut) internal returns (uint256 bnbOwed) {
        reward.mint(keeper, amount);
        vm.startPrank(keeper);
        reward.approve(address(vault), amount);
        bnbOwed = vault.sellRewardToVault(amount, minBnbOut);
        vm.stopPrank();
    }

    // ── schema / config ────────────────────────────────────────────────

    function testFactorySchema() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 5);
        assertEq(s.fields[0].name, "rewardToken");
        assertEq(s.fields[1].name, "rewardPriceFeed");
        assertEq(s.fields[2].name, "bnbPriceFeed");
        assertEq(s.fields[3].name, "basePriceWei");
        assertEq(s.fields[4].name, "seasonEnd");
        assertFalse(s.isArray);
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(RAM_TOKEN));
    }

    function testVaultSchema() public view {
        VaultUISchema memory ui = vault.vaultUISchema();
        assertEq(ui.vaultType, "RamMiningVault");
        assertEq(ui.methods.length, 9);
        assertEq(ui.methods[4].name, "buyMiningContract");
        assertTrue(ui.methods[4].isWriteMethod);
        assertEq(ui.methods[4].inputs[1].fieldType, "msg.value");
        assertEq(ui.methods[5].name, "claimRewards");
        assertTrue(ui.methods[5].isWriteMethod);
        assertEq(ui.methods[6].name, "quoteSellToVault");
        assertEq(ui.methods[7].name, "sellRewardToVault");
        assertTrue(ui.methods[7].isWriteMethod);
        assertEq(ui.methods[7].approvals[0].tokenType, "rewardToken");
        assertEq(ui.methods[8].name, "claimRewardsTo");
    }

    function testInitConfig() public view {
        assertEq(vault.taxToken(), RAM_TOKEN);
        assertEq(vault.rewardToken(), address(reward));
        assertEq(vault.rewardPriceFeed(), address(nvdaFeed));
        assertEq(vault.bnbPriceFeed(), address(bnbFeed));
        assertEq(vault.basePriceWei(), basePrice);
        assertEq(vault.seasonEnd(), seasonEnd);
        assertEq(vault.rewardTokenDecimals(), 18);
        assertEq(vault.keeperPremiumBps(), 10200);
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
        _buy(bob, 1); // 40 power -> total 50
        _inject(50 ether);
        assertApproxEqAbs(vault.pendingRewards(alice), 10 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 40 ether, 1e6);
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
        _buy(alice, 0); // Micro 10 power, 1 day
        _buy(bob, 1); // Core 40 power, 7 days -> total 50
        _inject(50 ether);

        vm.warp(block.timestamp + 2 days);
        _inject(40 ether);

        assertApproxEqAbs(vault.pendingRewards(alice), 10 ether, 1e6);
        assertApproxEqAbs(vault.pendingRewards(bob), 80 ether, 1e6);

        (,, uint256 power,,,,) = vault.getVaultMiningStats();
        assertEq(power, 40);
    }

    // ── keeper / RFQ acquisition ───────────────────────────────────────

    function testQuoteSellToVault() public view {
        // 1 NVDA @ $130 / $600 BNB = 0.21666.. BNB market, +2% premium = 0.221 BNB
        uint256 owed = vault.quoteSellToVault(1e18);
        uint256 expectedMarket = (1e18 * uint256(NVDA_USD)) / uint256(BNB_USD);
        uint256 expected = (expectedMarket * 10200) / 10000;
        assertEq(owed, expected);
    }

    function testQuoteDecimals8Equals18() public {
        // a fresh 8-decimal reward token vault should quote the SAME BNB for "1 token" as the 18-dec one
        MockRewardToken reward8 = new MockRewardToken(8);
        bytes memory vaultData =
            abi.encode(address(reward8), address(nvdaFeed), address(bnbFeed), basePrice, seasonEnd);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable v8 =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vaultData)));
        assertEq(v8.rewardTokenDecimals(), 8);

        uint256 owed8 = v8.quoteSellToVault(1e8); // 1 token in 8 dec
        uint256 owed18 = vault.quoteSellToVault(1e18); // 1 token in 18 dec
        assertEq(owed8, owed18);
    }

    function testSellHappyPathDistributesByPower() public {
        _buy(alice, 0); // 10 power, only miner
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        uint256 amount = 1e18;
        uint256 quoted = vault.quoteSellToVault(amount);
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
        vm.expectRevert(bytes(unicode"No miners / 没有矿工"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellMinBnbOutSlippage() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteSellToVault(1e18);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Slippage / 滑点过大"));
        vault.sellRewardToVault(1e18, quoted + 1); // demand more than the quote
        vm.stopPrank();
    }

    function testSellOverPerFillCapReverts() public {
        _buy(alice, 0);
        _armReference();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteSellToVault(1e18);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(quoted - 1, 100 ether); // per-fill cap below the quote

        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Over per-fill cap / 超过单次上限"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellWindowRateLimit() public {
        _buy(alice, 1); // Core rig (7 days) so the miner survives the 1-day window warp below
        _armReference();
        vm.deal(address(vault), 10 ether);

        uint256 quoted = vault.quoteSellToVault(1e18);
        vm.prank(GUARDIAN);
        vault.setKeeperLimits(quoted * 2, quoted); // window allows exactly ONE fill of 1e18

        _sell(1e18, 0); // first fill OK

        // second fill within the same window breaches the window cap
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Over window cap / 超过窗口上限"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();

        // after the window rolls over, a fill is allowed again
        vm.warp(block.timestamp + vault.WINDOW());
        _freshFeeds();
        uint256 owed = _sell(1e18, 0);
        assertEq(owed, quoted);
    }

    function testSellDeviationBandReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // arm the band at the current price, then move the feed > 2% away
        vm.prank(GUARDIAN);
        vault.setReferencePrice(uint256(NVDA_USD));
        nvdaFeed.setAnswer(140e8); // +7.7% vs reference 130

        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Price out of band / 价格超出区间"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSellWithinDeviationBandOk() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        vm.prank(GUARDIAN);
        vault.setReferencePrice(uint256(NVDA_USD));
        nvdaFeed.setAnswer(131e8); // +0.77% within the 2% band

        uint256 owed = _sell(1e18, 0);
        assertGt(owed, 0);
    }

    function testSellStaleRewardFeedReverts() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // NVDA/USD older than rewardFeedMaxStale (default 1 day) -> revert (weekend-freeze guard)
        nvdaFeed.setUpdatedAt(block.timestamp - 2 days);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Stale feed / 预言机数据过期"));
        vault.sellRewardToVault(1e18, 0);
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
        vm.expectRevert(bytes(unicode"Stale feed / 预言机数据过期"));
        vault.sellRewardToVault(1e18, 0);
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
        vm.expectRevert(bytes(unicode"Bad feed price / 预言机价格无效"));
        vault.sellRewardToVault(1e18, 0);
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
        vm.expectRevert(bytes(unicode"Stale round / 预言机轮次过期"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    function testAcquisitionPausedBlocksSellButNotClaim() public {
        _buy(alice, 0);
        _armKeeper();
        _freshFeeds();
        vm.deal(address(vault), 10 ether);

        // give alice some pending first
        _sell(1e18, 0);
        assertGt(vault.pendingRewards(alice), 0);

        // guardian pauses acquisition
        vm.prank(GUARDIAN);
        vault.pauseAcquisition();
        assertTrue(vault.acquisitionPaused());

        // sell now reverts
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Acquisition paused / 收购已暂停"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();

        // claim STILL works
        uint256 pending = vault.pendingRewards(alice);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertApproxEqAbs(got, pending, 100);

        // guardian can resume
        vm.prank(GUARDIAN);
        vault.resumeAcquisition();
        assertFalse(vault.acquisitionPaused());
    }

    function testSellDisabledByDefault() public {
        // caps are 0 at init -> any sell is over the per-fill cap
        _buy(alice, 0);
        _freshFeeds();
        vm.deal(address(vault), 10 ether);
        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Over per-fill cap / 超过单次上限"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    function testSetKeeperPremiumOnlyGuardianAndClamped() public {
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.setKeeperPremium(10100);

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Premium out of range / 溢价超范围"));
        vault.setKeeperPremium(9999); // below MIN

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Premium out of range / 溢价超范围"));
        vault.setKeeperPremium(10301); // above MAX

        vm.prank(GUARDIAN);
        vault.setKeeperPremium(10150);
        assertEq(vault.keeperPremiumBps(), 10150);
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

    // ── emergency reward rescue (must-fix #3 + blocker #3 pause-gate) ───

    function testEmergencyRescueRequiresPauseManager() public {
        // no pause oracle wired -> cannot even schedule
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Pause oracle not set / 未设置暂停预言机"));
        vault.scheduleEmergencyRescue();
    }

    function testEmergencyRescueRequiresTokenPausedToSchedule() public {
        MockPauseManager pm = new MockPauseManager();
        vm.prank(GUARDIAN);
        vault.setPauseManager(address(pm));

        // pause oracle says NOT paused -> schedule reverts
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Reward not paused / 奖励未暂停"));
        vault.scheduleEmergencyRescue();
    }

    function testEmergencyRescuePauseGatedTimelock() public {
        _buy(alice, 0);
        _inject(10 ether); // vault holds reward

        MockPauseManager pm = new MockPauseManager();
        vm.prank(GUARDIAN);
        vault.setPauseManager(address(pm));
        pm.setPaused(true); // reward token is paused (per the compliance oracle)

        // not scheduled -> reverts
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Rescue not scheduled / 未安排救援"));
        vault.emergencyRescueReward(GUARDIAN);

        vm.prank(GUARDIAN);
        vault.scheduleEmergencyRescue();

        // too early
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        vault.emergencyRescueReward(GUARDIAN);

        vm.warp(block.timestamp + vault.RESCUE_TIMELOCK());
        uint256 bal = reward.balanceOf(address(vault));
        vm.prank(GUARDIAN);
        vault.emergencyRescueReward(GUARDIAN);
        assertEq(reward.balanceOf(GUARDIAN), bal);
    }

    function testEmergencyRescueSelfCancelsIfPauseLifted() public {
        _buy(alice, 0);
        _inject(10 ether);

        MockPauseManager pm = new MockPauseManager();
        vm.prank(GUARDIAN);
        vault.setPauseManager(address(pm));
        pm.setPaused(true);

        vm.prank(GUARDIAN);
        vault.scheduleEmergencyRescue();
        vm.warp(block.timestamp + vault.RESCUE_TIMELOCK());

        // pause lifted during the timelock -> execute CONSUMES the schedule WITHOUT transferring (no revert)
        pm.setPaused(false);
        uint256 vaultBalBefore = reward.balanceOf(address(vault));
        vm.prank(GUARDIAN);
        vault.emergencyRescueReward(GUARDIAN);
        assertEq(reward.balanceOf(address(vault)), vaultBalBefore, "nothing transferred");
        assertEq(reward.balanceOf(GUARDIAN), 0);
        assertFalse(vault.rescueScheduled(), "schedule consumed");

        // a transient re-pause cannot drain on the old elapsed timelock: a fresh schedule + new 30d wait is needed
        pm.setPaused(true);
        vm.prank(GUARDIAN);
        vault.scheduleEmergencyRescue();
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        vault.emergencyRescueReward(GUARDIAN);
    }

    function testEmergencyRescueOnlyGuardian() public {
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.scheduleEmergencyRescue();
    }

    function testSetPauseManagerSetOnce() public {
        MockPauseManager pm1 = new MockPauseManager();
        MockPauseManager pm2 = new MockPauseManager();
        vm.prank(GUARDIAN);
        vault.setPauseManager(address(pm1));
        assertEq(vault.pauseManager(), address(pm1));

        // cannot be changed afterwards (anti-spoof: would require a timelocked beacon upgrade)
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Pause oracle already set / 暂停预言机已设置"));
        vault.setPauseManager(address(pm2));
    }

    function testEmergencyWithdrawTokenCannotDrainReward() public {
        _inject(10 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Use emergencyRescueReward / 请用奖励救援"));
        vault.emergencyWithdrawToken(address(reward), GUARDIAN);
    }

    // ── edges / audit-fix coverage ─────────────────────────────────────

    function testMaxRigsCap() public {
        for (uint256 i = 0; i < 16; i++) {
            _buy(alice, 0);
        }
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Too many rigs / 矿机数量过多"));
        vault.buyMiningContract{value: price}(0);
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

    function testPausableBlocksBuy() public {
        vm.prank(GUARDIAN);
        vault.pauseVault();
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert();
        vault.buyMiningContract{value: price}(0);

        vm.prank(GUARDIAN);
        vault.unpauseVault();
        _buy(alice, 0);
        (uint256 count,,,,) = vault.getUserMinerStats(alice);
        assertEq(count, 1);
    }

    function testBuyAfterSeasonEndReverts() public {
        vm.warp(seasonEnd + 1);
        (uint256 price,,,) = vault.getPlan(0);
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Mining season ended / 挖矿赛季已结束"));
        vault.buyMiningContract{value: price}(0);
    }

    function testEmergencyWithdrawNativeTimelock() public {
        vm.deal(address(vault), 3 ether);

        // without a schedule -> reverts
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Withdraw not scheduled / 未安排提取"));
        vault.emergencyWithdrawNative(GUARDIAN);

        // schedule, but execute before the timelock -> reverts
        vm.prank(GUARDIAN);
        vault.scheduleEmergencyWithdrawNative();
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        vault.emergencyWithdrawNative(GUARDIAN);

        // after the 7-day timelock -> succeeds, drains BNB
        vm.warp(block.timestamp + vault.NATIVE_WITHDRAW_TIMELOCK());
        uint256 balBefore = GUARDIAN.balance;
        vm.prank(GUARDIAN);
        vault.emergencyWithdrawNative(GUARDIAN);
        assertEq(address(vault).balance, 0);
        assertEq(GUARDIAN.balance, balBefore + 3 ether);

        // schedule is consumed -> a second withdraw needs a fresh schedule
        vm.deal(address(vault), 1 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Withdraw not scheduled / 未安排提取"));
        vault.emergencyWithdrawNative(GUARDIAN);
    }

    function testScheduleEmergencyWithdrawNativeOnlyGuardian() public {
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.scheduleEmergencyWithdrawNative();
    }

    function testEmergencyWithdrawNativeOnlyGuardian() public {
        vm.deal(address(vault), 1 ether);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.emergencyWithdrawNative(alice);
    }

    // ── adversarial gate: blockers #1, #4, #5, #7, #9 ──────────────────

    /// blocker #1: a rig whose endBucket lands in the already-settled (last) bucket must be rejected, not bricked.
    function testLastBucketBrickRejected() public {
        // short season so a rig can be capped into the current bucket near seasonEnd
        uint256 shortSeason = block.timestamp + 36 hours; // 1.5 days (>= block.timestamp + 1 day)
        bytes memory vd =
            abi.encode(address(reward), address(nvdaFeed), address(bnbFeed), basePrice, shortSeason);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        RamMiningVaultUpgradeable v =
            RamMiningVaultUpgradeable(payable(factory.newVault(RAM_TOKEN, address(0), address(this), vd)));

        (uint256 price,,,) = v.getPlan(0);
        vm.deal(alice, 1 ether);

        // normal buy now: rig ends in a FUTURE bucket -> OK
        vm.prank(alice);
        v.buyMiningContract{value: price}(0);

        // warp into the season-end bucket: a new rig's end caps to seasonEnd in the already-settled bucket -> reject
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Rig ends too soon / 套餐过短"));
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
        uint256 expectedOwed = v.quoteSellToVault(received);

        fee.mint(keeper, amount);
        uint256 keeperBnbBefore = keeper.balance;
        vm.startPrank(keeper);
        fee.approve(address(v), amount);
        uint256 owed = v.sellRewardToVault(amount, 0);
        vm.stopPrank();

        assertEq(owed, expectedOwed, "paid on received delta");
        assertEq(keeper.balance, keeperBnbBefore + expectedOwed);
        assertEq(fee.balanceOf(address(v)), received, "vault holds the real delta");
        assertApproxEqAbs(v.pendingRewards(alice), received, 100);
        // nominal-based payout would have been strictly larger -> confirms we did NOT overpay
        assertGt(v.quoteSellToVault(amount), expectedOwed);
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
        uint256 quoted = vault.quoteSellToVault(amount);

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
        vm.expectRevert(bytes(unicode"Reward feed not 8dec / 奖励预言机非8位"));
        vault.setPriceFeeds(address(bad), address(bnbFeed));

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"BNB feed not 8dec / BNB预言机非8位"));
        vault.setPriceFeeds(address(nvdaFeed), address(bad));
    }

    function testInitRejectsNon8DecimalFeed() public {
        MockPriceFeed bad = new MockPriceFeed(6, 100e8);
        bytes memory vd = abi.encode(address(reward), address(bad), address(bnbFeed), basePrice, seasonEnd);
        vm.prank(BNB_TESTNET_VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Reward feed not 8dec / 奖励预言机非8位"));
        factory.newVault(RAM_TOKEN, address(0), address(this), vd);
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
        vm.expectRevert(bytes(unicode"Arm reference price first / 请先设定参考价"));
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
        vm.expectRevert(bytes(unicode"Arm reference price first / 请先设置参考价"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();

        // re-arming the reference restores sells
        _armReference();
        assertGt(_sell(1e18, 0), 0);
    }

    /// blocker #4a: a frozen NVDA/USD feed (older than the tight 1h default) makes sell REVERT = de-facto pause.
    function testFrozenFeedDeFactoPausesSell() public {
        _buy(alice, 0);
        _armKeeper();
        vm.deal(address(vault), 10 ether);

        bnbFeed.refresh(); // BNB feed fresh (24/7)
        nvdaFeed.setUpdatedAt(block.timestamp - 90 minutes); // > 1h default -> stale (market closed)

        reward.mint(keeper, 1e18);
        vm.startPrank(keeper);
        reward.approve(address(vault), 1e18);
        vm.expectRevert(bytes(unicode"Stale feed / 预言机数据过期"));
        vault.sellRewardToVault(1e18, 0);
        vm.stopPrank();
    }

    // ── factory upgrade timelock ───────────────────────────────────────

    function testUpgradeTimelock() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();

        vm.prank(GUARDIAN);
        factory.scheduleUpgrade(address(newImpl));

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Timelock not elapsed / 时间锁未到"));
        factory.executeUpgrade();

        vm.warp(block.timestamp + factory.UPGRADE_DELAY());
        vm.prank(GUARDIAN);
        factory.executeUpgrade();
        assertEq(factory.beaconImplementation(), address(newImpl));
    }

    function testScheduleUpgradeOnlyGuardian() public {
        RamMiningVaultUpgradeable newImpl = new RamMiningVaultUpgradeable();
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.scheduleUpgrade(address(newImpl));
    }

    // ── invariants ─────────────────────────────────────────────────────

    function testNoDoubleClaim() public {
        _buy(alice, 0);
        _inject(10 ether);
        vm.prank(alice);
        vault.claimRewards();
        vm.prank(alice);
        vm.expectRevert(bytes(unicode"Nothing to claim / 无可领取"));
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
        _buy(alice, 2); // Mega: 130 power, 30 days
        (uint256 id, uint256 planId, uint256 power,,,, uint256 pending, bool active) =
            vault.getMiningContract(alice, 0);
        assertEq(id, 1);
        assertEq(planId, 2);
        assertEq(power, 130);
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
