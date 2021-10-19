pragma solidity ^0.6.7;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import {SAFEEngine} from 'geb/SAFEEngine.sol';
import {Coin} from 'geb/Coin.sol';
import {LiquidationEngine} from 'geb/LiquidationEngine.sol';
import {AccountingEngine} from 'geb/AccountingEngine.sol';
import {TaxCollector} from 'geb/TaxCollector.sol';
import 'geb/BasicTokenAdapters.sol';
import {OracleRelayer} from 'geb/OracleRelayer.sol';
import {EnglishCollateralAuctionHouse} from 'geb/CollateralAuctionHouse.sol';
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import "../integrations/yearn/YearnVault3Mock.sol";
import {YearnV3MaxSystemCoinSafeSaviour} from "../saviours/YearnV3MaxSystemCoinSafeSaviour.sol";

abstract contract Hevm {
  function warp(uint256) virtual public;
}

// --- Median Contracts ---
contract MockMedianizer {
    uint256 public price;
    bool public validPrice;
    uint public lastUpdateTime;
    address public priceSource;

    constructor(uint256 price_, bool validPrice_) public {
        price = price_;
        validPrice = validPrice_;
        lastUpdateTime = now;
    }
    function updatePriceSource(address priceSource_) external {
        priceSource = priceSource_;
    }
    function changeValidity() external {
        validPrice = !validPrice;
    }
    function updateCollateralPrice(uint256 price_) external {
        price = price_;
        lastUpdateTime = now;
    }
    function read() external view returns (uint256) {
        return price;
    }
    function getResultWithValidity() external view returns (uint256, bool) {
        return (price, validPrice);
    }
}

contract TestSAFEEngine is SAFEEngine {
    uint256 constant RAY = 10 ** 27;

    constructor() public {}

    function mint(address usr, uint wad) public {
        coinBalance[usr] += wad * RAY;
        globalDebt += wad * RAY;
    }
    function balanceOf(address usr) public view returns (uint) {
        return uint(coinBalance[usr] / RAY);
    }
}

// Users
contract FakeUser {
    function doModifyParameters(
      YearnV3MaxSystemCoinSafeSaviour saviour,
      bytes32 parameter,
      uint256 data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
      YearnV3MaxSystemCoinSafeSaviour saviour,
      bytes32 parameter,
      address data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doOpenSafe(
        GebSafeManager manager,
        bytes32 collateralType,
        address usr
    ) public returns (uint256) {
        return manager.openSAFE(collateralType, usr);
    }

    function doSafeAllow(
        GebSafeManager manager,
        uint safe,
        address usr,
        uint ok
    ) public {
        manager.allowSAFE(safe, usr, ok);
    }

    function doHandlerAllow(
        GebSafeManager manager,
        address usr,
        uint ok
    ) public {
        manager.allowHandler(usr, ok);
    }

    function doTransferSAFEOwnership(
        GebSafeManager manager,
        uint safe,
        address dst
    ) public {
        manager.transferSAFEOwnership(safe, dst);
    }

    function doModifySAFECollateralization(
        GebSafeManager manager,
        uint safe,
        int deltaCollateral,
        int deltaDebt
    ) public {
        manager.modifySAFECollateralization(safe, deltaCollateral, deltaDebt);
    }

    function doApproveSAFEModification(
        SAFEEngine safeEngine,
        address usr
    ) public {
        safeEngine.approveSAFEModification(usr);
    }

    function doSAFEEngineModifySAFECollateralization(
        SAFEEngine safeEngine,
        bytes32 collateralType,
        address safe,
        address collateralSource,
        address debtDst,
        int deltaCollateral,
        int deltaDebt
    ) public {
        safeEngine.modifySAFECollateralization(collateralType, safe, collateralSource, debtDst, deltaCollateral, deltaDebt);
    }

    function doProtectSAFE(
        GebSafeManager manager,
        uint safe,
        address liquidationEngine,
        address saviour
    ) public {
        manager.protectSAFE(safe, liquidationEngine, saviour);
    }

    function doDeposit(
        YearnV3MaxSystemCoinSafeSaviour saviour,
        DSToken systemCoin,
        bytes32 collateralType,
        uint safe,
        uint amount
    ) public {
        systemCoin.approve(address(saviour), amount);
        saviour.deposit(collateralType, safe, amount);
    }

    function doWithdraw(
        YearnV3MaxSystemCoinSafeSaviour saviour,
        bytes32 collateralType,
        uint safe,
        uint amount,
        uint maxLoss,
        address dst
    ) public {
        saviour.withdraw(collateralType, safe, amount, maxLoss, dst);
    }

    function doTransferInternalCoins(
        GebSafeManager manager,
        uint256 safe,
        address dst,
        uint256 amt
    ) external {
        manager.transferInternalCoins(safe, dst, amt);
    }
}

contract YearnV3MaxSystemCoinSafeSaviourTest is DSTest {
    Hevm hevm;

    TestSAFEEngine safeEngine;
    AccountingEngine accountingEngine;
    LiquidationEngine liquidationEngine;
    OracleRelayer oracleRelayer;
    TaxCollector taxCollector;

    BasicCollateralJoin collateralJoin;

    CoinJoin coinJoin;

    EnglishCollateralAuctionHouse collateralAuctionHouse;

    GebSafeManager safeManager;

    MockMedianizer systemCoinOracle;
    MockMedianizer ethFSM;
    MockMedianizer ethMedian;

    Coin systemCoin;
    WETH9_ weth;

    YearnVault3Mock yearnVault;
    YearnV3MaxSystemCoinSafeSaviour saviour;

    SAFESaviourRegistry saviourRegistry;

    FakeUser alice;
    address me;

    // General params
    uint256 initTokenAmount  = 100000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initRAIUSDPrice  = 4.242 * 10 ** 18;

    // Saviour parameters
    uint256 saveCooldown = 1 days;
    uint256 minKeeperPayoutValue = 1000 ether;
    uint256 defaultMaxLoss = 100;

    // Core system params
    uint256 minCRatio = 1.5 ether;
    uint256 ethToMint = 5000 ether;
    uint256 ethCeiling = uint(-1);
    uint256 ethFloor = 10 ether;
    uint256 ethLiquidationPenalty = 1 ether;

    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;
    uint256 defaultSystemCoinDeposit = 10000 ether;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        // System coin
        systemCoin = new Coin("RAI", "RAI", 1);
        systemCoin.mint(address(this), initTokenAmount);
        systemCoinOracle = new MockMedianizer(initRAIUSDPrice, true);

        // Core system
        safeEngine = new TestSAFEEngine();
        safeEngine.initializeCollateralType("eth");
        safeEngine.mint(address(this), rad(initTokenAmount));

        ethFSM    = new MockMedianizer(initETHUSDPrice, true);
        ethMedian = new MockMedianizer(initETHUSDPrice, true);
        ethFSM.updatePriceSource(address(ethMedian));

        oracleRelayer = new OracleRelayer(address(safeEngine));
        oracleRelayer.modifyParameters("redemptionPrice", ray(initRAIUSDPrice));
        oracleRelayer.modifyParameters("eth", "orcl", address(ethFSM));
        oracleRelayer.modifyParameters("eth", "safetyCRatio", ray(minCRatio));
        oracleRelayer.modifyParameters("eth", "liquidationCRatio", ray(minCRatio));

        safeEngine.addAuthorization(address(oracleRelayer));
        oracleRelayer.updateCollateralPrice("eth");

        accountingEngine = new AccountingEngine(
          address(safeEngine), address(0x1), address(0x2)
        );
        safeEngine.addAuthorization(address(accountingEngine));

        taxCollector = new TaxCollector(address(safeEngine));
        taxCollector.initializeCollateralType("eth");
        taxCollector.modifyParameters("primaryTaxReceiver", address(accountingEngine));
        taxCollector.modifyParameters("eth", "stabilityFee", 1000000564701133626865910626);  // 5% / day
        safeEngine.addAuthorization(address(taxCollector));

        liquidationEngine = new LiquidationEngine(address(safeEngine));
        liquidationEngine.modifyParameters("accountingEngine", address(accountingEngine));

        safeEngine.addAuthorization(address(liquidationEngine));
        accountingEngine.addAuthorization(address(liquidationEngine));

        weth = new WETH9_();
        weth.deposit{value: initTokenAmount}();

        collateralJoin = new BasicCollateralJoin(address(safeEngine), "eth", address(weth));

        coinJoin = new CoinJoin(address(safeEngine), address(systemCoin));
        systemCoin.addAuthorization(address(coinJoin));
        safeEngine.transferInternalCoins(address(this), address(coinJoin), safeEngine.coinBalance(address(this)));

        safeEngine.addAuthorization(address(collateralJoin));

        safeEngine.modifyParameters("eth", "debtCeiling", rad(ethCeiling));
        safeEngine.modifyParameters("globalDebtCeiling", rad(ethCeiling));
        safeEngine.modifyParameters("eth", "debtFloor", rad(ethFloor));

        collateralAuctionHouse = new EnglishCollateralAuctionHouse(address(safeEngine), address(liquidationEngine), "eth");
        collateralAuctionHouse.addAuthorization(address(liquidationEngine));

        liquidationEngine.addAuthorization(address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("eth", "collateralAuctionHouse", address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", ethLiquidationPenalty);

        safeEngine.addAuthorization(address(collateralAuctionHouse));
        safeEngine.approveSAFEModification(address(collateralAuctionHouse));

        safeManager = new GebSafeManager(address(safeEngine));
        oracleRelayer.updateCollateralPrice("eth");

        // Yearn setup
        yearnVault = new YearnVault3Mock(true, address(systemCoin), 10**18);

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);

        saviour = new YearnV3MaxSystemCoinSafeSaviour(
            address(coinJoin),
            address(systemCoinOracle),
            address(liquidationEngine),
            address(taxCollector),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(yearnVault),
            minKeeperPayoutValue
        );
        yearnVault.setOwner(address(saviour));
        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        me    = address(this);
        alice = new FakeUser();

        // Mint Curve related tokens
        systemCoin.mint(address(yearnVault), initTokenAmount * initTokenAmount * 100);
        systemCoin.mint(address(alice), initTokenAmount * initTokenAmount);
    }

    // --- Math ---
    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }
    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    // --- Default actions/scenarios ---
    function default_create_liquidatable_position(uint256 liquidatableCollateralPrice) internal returns (address) {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(liquidatableCollateralPrice);
        ethFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("eth");

        return safeHandler;
    }
    function default_save(uint256 safe, address safeHandler) internal {
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(initETHUSDPrice / 2);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 2);
        oracleRelayer.updateCollateralPrice("eth");

        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", safe, initTokenAmount * initTokenAmount / 10);
        assertEq(yearnVault.balanceOf(address(saviour)), initTokenAmount * initTokenAmount / 10);
        assertEq(saviour.yvTokenCover("eth", safeHandler), initTokenAmount * initTokenAmount / 10);

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(100000 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(address(this));
        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);

        assertEq(auction, 0);
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0
        );
        assertTrue(saviour.yvTokenCover("eth", safeHandler) > 0);
        assertEq(saviour.yvTokenCover("eth", safeHandler), yearnVault.balanceOf(address(saviour)));
        assertEq(systemCoin.balanceOf(address(saviour)), 0);
    }
    function default_second_save(uint256 safe, address safeHandler) internal {
        alice.doModifySAFECollateralization(safeManager, safe, 0, int(defaultTokenAmount * 4));

        ethMedian.updateCollateralPrice(initETHUSDPrice / 5);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 5);
        oracleRelayer.updateCollateralPrice("eth");

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(address(this));
        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);

        assertEq(auction, 0);
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0
        );
        assertTrue(saviour.yvTokenCover("eth", safeHandler) > 0);
        assertEq(saviour.yvTokenCover("eth", safeHandler), yearnVault.balanceOf(address(saviour)));
        assertEq(systemCoin.balanceOf(address(saviour)), 0);
    }
    function default_liquidate_safe(address safeHandler) internal {
        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(100000 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        // the full SAFE is liquidated
        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", me);
        assertEq(lockedCollateral, 0);
        assertEq(generatedDebt, 0);
        // all debt goes to the accounting engine
        assertTrue(accountingEngine.totalQueuedDebt() > 0);
        // auction is for all collateral
        (,uint amountToSell,,,,,, uint256 amountToRaise) = collateralAuctionHouse.bids(auction);
        assertEq(amountToSell, defaultCollateralAmount);
        assertEq(amountToRaise, rad(1100 ether));
    }
    function default_create_liquidatable_position_deposit_cover(uint256 liquidatableCollateralPrice)
      internal returns (address) {
        // Create position
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        // Change oracle price
        ethMedian.updateCollateralPrice(liquidatableCollateralPrice);
        ethFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("eth");

        // Deposit cover
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", safe, defaultSystemCoinDeposit);
        assertEq(yearnVault.balanceOf(address(saviour)), defaultSystemCoinDeposit);
        assertEq(saviour.yvTokenCover("eth", safeHandler), defaultSystemCoinDeposit);

        return safeHandler;
    }
    function default_create_position_deposit_cover() internal returns (uint, address) {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        // Deposit cover
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", safe, defaultSystemCoinDeposit);
        assertEq(yearnVault.balanceOf(address(saviour)), defaultSystemCoinDeposit);
        assertEq(saviour.yvTokenCover("eth", safeHandler), defaultSystemCoinDeposit);

        return (safe, safeHandler);
    }
    function default_modify_collateralization(uint256 safe, address safeHandler) internal {
        weth.approve(address(collateralJoin), uint(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount * 10));
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);
        assertEq(saviour.restrictUsage(), 0);

        assertEq(address(saviour.coinJoin()), address(coinJoin));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.systemCoin()), address(systemCoin));
        assertEq(address(saviour.safeEngine()), address(safeEngine));
        assertEq(address(saviour.safeManager()), address(safeManager));
        assertEq(address(saviour.saviourRegistry()), address(saviourRegistry));
        assertEq(address(saviour.yVault()), address(yearnVault));
    }
    function test_modify_uints() public {
        saviour.modifyParameters("minKeeperPayoutValue", 5);
        saviour.modifyParameters("restrictUsage", 1);

        assertEq(saviour.minKeeperPayoutValue(), 5);
        assertEq(saviour.restrictUsage(), 1);
    }
    function testFail_modify_uint_unauthed() public {
        alice.doModifyParameters(saviour, "minKeeperPayoutValue", 5);
    }
    function test_modify_addresses() public {
        saviour.modifyParameters("systemCoinOrcl", address(systemCoinOracle));
        saviour.modifyParameters("oracleRelayer", address(oracleRelayer));
        saviour.modifyParameters("taxCollector", address(taxCollector));

        assertEq(address(saviour.taxCollector()), address(taxCollector));
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
    }
    function testFail_modify_address_unauthed() public {
        alice.doModifyParameters(saviour, "systemCoinOrcl", address(systemCoinOracle));
    }
    function testFail_deposit_liq_engine_not_approved() public {
        liquidationEngine.disconnectSAFESaviour(address(saviour));

        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit);
    }
    function testFail_deposit_null_lp_token_amount() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, 0);
    }
    function testFail_deposit_inexistent_safe() public {
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit);
    }
    function test_deposit_twice() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();

        // Second deposit
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", safe, defaultSystemCoinDeposit);

        // Checks
        assertTrue(systemCoin.balanceOf(address(saviour)) == 0 && saviour.yvTokenCover("eth", safeHandler) > 0);
        assertEq(saviour.yvTokenCover("eth", safeHandler), defaultSystemCoinDeposit * 2);
        assertEq(yearnVault.balanceOf(address(saviour)), defaultSystemCoinDeposit * 2);
    }
    function test_deposit_after_everything_withdrawn() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentSysCoinBalanceAlice   = systemCoin.balanceOf(address(alice));
        uint256 currentSysCoinBalanceSaviour = yearnVault.balanceOf(address(saviour));
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler), defaultMaxLoss, address(alice));

        // Checks
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice + currentSysCoinBalanceSaviour);
        assertTrue(systemCoin.balanceOf(address(saviour)) == 0 && saviour.yvTokenCover("eth", safeHandler) == 0);
        assertEq(yearnVault.balanceOf(address(saviour)), 0);

        // Deposit again
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", safe, currentSysCoinBalanceSaviour);

        // Checks
        assertTrue(yearnVault.balanceOf(address(saviour)) > 0 && saviour.yvTokenCover("eth", safeHandler) > 0);
        assertEq(saviour.yvTokenCover("eth", safeHandler), currentSysCoinBalanceSaviour);
        assertEq(yearnVault.balanceOf(address(saviour)), currentSysCoinBalanceSaviour);
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice);
    }
    function testFail_withdraw_unauthorized() public {
        (uint safe, ) = default_create_position_deposit_cover();

        // Withdraw by unauthed
        FakeUser bob = new FakeUser();
        bob.doWithdraw(saviour, "eth", safe, yearnVault.balanceOf(address(saviour)), defaultMaxLoss, address(bob));
    }
    function testFail_withdraw_more_than_deposited() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler) + 1, defaultMaxLoss, address(this));
    }
    function testFail_withdraw_null() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();
        alice.doWithdraw(saviour, "eth", safe, 0, defaultMaxLoss, address(this));
    }
    function test_withdraw() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentSysCoinBalanceAlice   = systemCoin.balanceOf(address(alice));
        uint256 currentSysCoinBalanceSaviour = yearnVault.balanceOf(address(saviour));
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler), defaultMaxLoss, address(alice));

        // Checks
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice + currentSysCoinBalanceSaviour);
        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertEq(yearnVault.balanceOf(address(saviour)), 0);
    }
    function test_withdraw_twice() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentSysCoinBalanceAlice   = systemCoin.balanceOf(address(alice));
        uint256 currentSysCoinBalanceSaviour = yearnVault.balanceOf(address(saviour));
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler) / 2, defaultMaxLoss, address(alice));

        // Checks
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice + currentSysCoinBalanceSaviour / 2);
        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertEq(yearnVault.balanceOf(address(saviour)), currentSysCoinBalanceSaviour / 2);

        // Withdraw again
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler), defaultMaxLoss, address(alice));

        // Checks
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice + currentSysCoinBalanceSaviour);
        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertEq(yearnVault.balanceOf(address(saviour)), 0);
    }
    function test_withdraw_custom_dst() public {
        (uint safe, address safeHandler) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentSysCoinBalanceAlice   = systemCoin.balanceOf(address(alice));
        uint256 currentSysCoinBalanceSaviour = yearnVault.balanceOf(address(saviour));
        alice.doWithdraw(saviour, "eth", safe, saviour.yvTokenCover("eth", safeHandler), defaultMaxLoss, address(0xb1));

        // Checks
        assertEq(saviour.yvTokenCover("eth", safeHandler), 0);
        assertEq(systemCoin.balanceOf(address(0xb1)), currentSysCoinBalanceSaviour);
        assertEq(systemCoin.balanceOf(address(alice)), currentSysCoinBalanceAlice);
        assertEq(yearnVault.balanceOf(address(saviour)), 0);
        assertEq(yearnVault.balanceOf(address(saviour)), 0);
    }
    function test_getSystemCoinMarketPrice_invalid() public {
        systemCoinOracle.changeValidity();
        assertEq(saviour.getSystemCoinMarketPrice(), 0);
    }
    function test_getSystemCoinMarketPrice_null_price() public {
        systemCoinOracle.updateCollateralPrice(0);
        assertEq(saviour.getSystemCoinMarketPrice(), 0);
    }
    function test_getSystemCoinMarketPrice() public {
        assertEq(saviour.getSystemCoinMarketPrice(), initRAIUSDPrice);
    }
    function test_getTokensForSaving_no_cover() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);

        uint sysCoins = saviour.getTokensForSaving("eth", safeHandler, 10**18, 250 ether);

        assertEq(sysCoins, 0);
    }
    function test_getTokensForSaving_inexistent_position() public {
        uint sysCoins = saviour.getTokensForSaving("eth", address(0xb1), 10**18, 1);

        assertEq(sysCoins, 0);
    }
    function test_getTokensForSaving_no_debt() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        uint sysCoins = saviour.getTokensForSaving("eth", safeHandler, 10**18, 1);

        assertEq(sysCoins, 0);
    }
    function test_getTokensForSaving_coins_higher_than_debt() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit * 10);
        uint sysCoins = saviour.getTokensForSaving("eth", safeHandler, 10**18, 1);

        assertEq(sysCoins, defaultTokenAmount * 10);
    }
    function test_getTokensForSaving_keeper_fee_too_high() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit * 10);
        uint sysCoins = saviour.getTokensForSaving("eth", safeHandler, 10**18, 1_000_000E18);

        assertEq(sysCoins, 0);
    }
    function test_getTokensForSaving_coins_below_floor_and_debt() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit / 10);
        uint sysCoins = saviour.getTokensForSaving("eth", safeHandler, 10**18, 1);

        assertEq(sysCoins, 0);
    }
    function testFail_saveSAFE_invalid_caller() public {
        address safeHandler = default_create_liquidatable_position_deposit_cover(initETHUSDPrice / 2);
        saviour.saveSAFE(address(this), "eth", safeHandler);
    }
    function test_saveSAFE_no_cover() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);
        default_liquidate_safe(safeHandler);
    }
    function test_saveSAFE_cannot_save_safe() public {
        // Create position
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);

        weth.approve(address(collateralJoin), uint(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount * 10));

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        // Change oracle price
        ethMedian.updateCollateralPrice(initETHUSDPrice / 5);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 5);
        oracleRelayer.updateCollateralPrice("eth");

        // Deposit cover and make sure the pool barely sends tokens
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit / 20);
        default_liquidate_safe(safeHandler);

        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertEq(saviour.yvTokenCover("eth", safeHandler), defaultSystemCoinDeposit / 20);
    }
    function test_saveSAFE_cannot_pay_keeper() public {
        address safeHandler = default_create_liquidatable_position(initETHUSDPrice / 2);
        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit * 10);
        saviour.modifyParameters("minKeeperPayoutValue", 1_000_000_000 ether);
        default_liquidate_safe(safeHandler);
    }
    function test_saveSAFE() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);
    }
    function test_saveSAFE_accumulate_rate() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);

        // Warp and save
        hevm.warp(now + 2 days);
        taxCollector.taxSingle("eth");

        weth.approve(address(collateralJoin), uint(-1));
        collateralJoin.join(address(safeHandler), defaultCollateralAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount * 10));

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));

        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(initETHUSDPrice / 2);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 2);
        oracleRelayer.updateCollateralPrice("eth");

        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit * 100);
        assertEq(yearnVault.balanceOf(address(saviour)), defaultSystemCoinDeposit * 100);

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(100000 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance  = systemCoin.balanceOf(address(this));
        uint256 preSaveSysCoinSaviourBalance = yearnVault.balanceOf(address(saviour));

        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);

        assertEq(auction, 0);
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0 ||
          preSaveSysCoinSaviourBalance - yearnVault.balanceOf(address(saviour)) > 0
        );
        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertTrue(saviour.yvTokenCover("eth", safeHandler) > 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        (, uint accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(lockedCollateral * ray(ethFSM.read()) * 100 / (generatedDebt * oracleRelayer.redemptionPrice() * accumulatedRate / 10 ** 27) >= minCRatio / 10**17);
    }
    function test_saveSAFE_accumulate_rate_yearn_accumulates_gains() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);

        // Warp and save
        hevm.warp(now + 2 days);
        taxCollector.taxSingle("eth");

        weth.approve(address(collateralJoin), uint(-1));
        collateralJoin.join(address(safeHandler), defaultCollateralAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount * 10));

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));

        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(initETHUSDPrice / 2);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 2);
        oracleRelayer.updateCollateralPrice("eth");

        alice.doDeposit(saviour, DSToken(address(systemCoin)), "eth", 1, defaultSystemCoinDeposit * 100);
        assertEq(yearnVault.balanceOf(address(saviour)), defaultSystemCoinDeposit * 100);

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(100000 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance  = systemCoin.balanceOf(address(this));
        uint256 preSaveSysCoinSaviourBalance = yearnVault.balanceOf(address(saviour));

        yearnVault.setSharePrice(10**18 * 2);
        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);

        assertEq(auction, 0);
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0 ||
          preSaveSysCoinSaviourBalance - yearnVault.balanceOf(address(saviour)) > 0
        );
        assertEq(yearnVault.balanceOf(address(saviour)), saviour.yvTokenCover("eth", safeHandler));
        assertTrue(saviour.yvTokenCover("eth", safeHandler) > 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        (, uint accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(lockedCollateral * ray(ethFSM.read()) * 100 / (generatedDebt * oracleRelayer.redemptionPrice() * accumulatedRate / 10 ** 27) >= minCRatio / 10**17);
    }
    function test_saveSAFE_twice() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        hevm.warp(now + saviourRegistry.saveCooldown() + 1);
        default_second_save(safe, safeHandler);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        (, uint accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(lockedCollateral * ray(ethFSM.read()) * 100 / (generatedDebt * oracleRelayer.redemptionPrice() * accumulatedRate / 10 ** 27) >= minCRatio / 10**17);
    }
    function test_saveSAFE_twice_yearn_compounds_gains() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        yearnVault.setSharePrice(10**18 * 2);

        hevm.warp(now + saviourRegistry.saveCooldown() + 1);
        default_second_save(safe, safeHandler);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        (, uint accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(lockedCollateral * ray(ethFSM.read()) * 100 / (generatedDebt * oracleRelayer.redemptionPrice() * accumulatedRate / 10 ** 27) >= minCRatio / 10**17);
    }
    function test_saveSAFE_twice_yearn_loses_gains() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        yearnVault.setSharePrice(10**18 * 12 / 10);

        hevm.warp(now + saviourRegistry.saveCooldown() + 1);
        default_second_save(safe, safeHandler);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        (, uint accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(lockedCollateral * ray(ethFSM.read()) * 100 / (generatedDebt * oracleRelayer.redemptionPrice() * accumulatedRate / 10 ** 27) >= minCRatio / 10**17);
    }
    function testFail_save_twice_without_waiting() public {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);
        default_second_save(safe, safeHandler);
    }
}
