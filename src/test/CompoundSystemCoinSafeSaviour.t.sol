pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import {SAFEEngine} from 'geb/SAFEEngine.sol';
import {Coin} from 'geb/Coin.sol';
import {LiquidationEngine} from 'geb/LiquidationEngine.sol';
import {AccountingEngine} from 'geb/AccountingEngine.sol';
import {TaxCollector} from 'geb/TaxCollector.sol';
import {BasicCollateralJoin, CoinJoin} from 'geb/BasicTokenAdapters.sol';
import {OracleRelayer} from 'geb/OracleRelayer.sol';
import {EnglishCollateralAuctionHouse} from 'geb/CollateralAuctionHouse.sol';
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import {CErc20, CToken} from "../integrations/compound/CErc20.sol";
import {ComptrollerG2} from "../integrations/compound/ComptrollerG2.sol";
import {Unitroller} from "../integrations/compound/Unitroller.sol";
import {WhitePaperInterestRateModel} from "../integrations/compound/WhitePaperInterestRateModel.sol";
import {PriceOracle} from "../integrations/compound/PriceOracle.sol";

import {SaviourCRatioSetter} from "../SaviourCRatioSetter.sol";
import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import {CompoundSystemCoinSafeSaviour} from "../saviours/CompoundSystemCoinSafeSaviour.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}
contract CompoundPriceOracle is PriceOracle {
    uint256 price;

    function setPrice(uint256 newPrice) public {
        price = newPrice;
    }

    function getUnderlyingPrice(CToken cToken) override external view returns (uint) {
        return price;
    }
}
contract Feed {
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
contract TestAccountingEngine is AccountingEngine {
    constructor(address safeEngine, address surplusAuctionHouse, address debtAuctionHouse)
        public AccountingEngine(safeEngine, surplusAuctionHouse, debtAuctionHouse) {}

    function totalDeficit() public view returns (uint) {
        return safeEngine.debtBalance(address(this));
    }
    function totalSurplus() public view returns (uint) {
        return safeEngine.coinBalance(address(this));
    }
    function preAuctionDebt() public view returns (uint) {
        return subtract(subtract(totalDeficit(), totalQueuedDebt), totalOnAuctionDebt);
    }
}
contract FakeUser {
    function doModifyParameters(
      CompoundSystemCoinSafeSaviour saviour,
      bytes32 parameter,
      uint256 data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
      CompoundSystemCoinSafeSaviour saviour,
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
        CompoundSystemCoinSafeSaviour saviour,
        Coin systemCoin,
        bytes32 collateralType,
        uint256 safeID,
        uint256 systemCoinAmount
    ) public {
        systemCoin.approve(address(saviour), systemCoinAmount);
        saviour.deposit(collateralType, safeID, systemCoinAmount);
    }

    function doWithdraw(
        CompoundSystemCoinSafeSaviour saviour,
        bytes32 collateralType,
        uint256 safeID,
        uint256 cTokenAmount
    ) public {
        saviour.withdraw(collateralType, safeID, cTokenAmount);
    }

    function doTransferInternalCoins(
        GebSafeManager manager,
        uint256 safe,
        address dst,
        uint256 amt
    ) public {
        manager.transferInternalCoins(safe, dst, amt);
    }

    function doSetDesiredCollateralizationRatio(
        SaviourCRatioSetter cRatioSetter,
        bytes32 collateralType,
        uint safe,
        uint cRatio
    ) public {
        cRatioSetter.setDesiredCollateralizationRatio(collateralType, safe, cRatio);
    }
}

contract CompoundSystemCoinSafeSaviourTest is DSTest {
    Hevm hevm;

    TestSAFEEngine safeEngine;
    TestAccountingEngine accountingEngine;
    LiquidationEngine liquidationEngine;
    OracleRelayer oracleRelayer;
    TaxCollector taxCollector;

    BasicCollateralJoin collateralJoin;
    CoinJoin coinJoin;

    CoinJoin systemCoinJoin;
    EnglishCollateralAuctionHouse collateralAuctionHouse;

    GebSafeManager safeManager;

    Feed systemCoinOracle;
    CompoundPriceOracle compoundSysCoinOracle;

    Coin systemCoin;

    CompoundSystemCoinSafeSaviour saviour;
    SaviourCRatioSetter cRatioSetter;
    SAFESaviourRegistry saviourRegistry;

    CErc20 cRAI;
    ComptrollerG2 comptroller;
    Unitroller unitroller;
    WhitePaperInterestRateModel interestRateModel;

    FakeUser alice;

    Feed goldFSM;
    Feed goldMedian;

    DSToken gold;

    address me;

    // Compound Params
    uint256 systemCoinsToMint = 100000 * 10**18;
    uint256 systemCoinPrice = 1 ether;

    uint256 baseRatePerYear = 10**17;
    uint256 multiplierPerYear = 45 * 10**17;
    uint256 liquidationIncentive = 1 ether;
    uint256 closeFactor = 0.051 ether;
    uint256 maxAssets = 10;
    uint256 exchangeRate = 1 ether;

    uint8 cTokenDecimals = 8;

    string cTokenSymbol = "cRAI";
    string cTokenName = "cRAI";

    // Saviour params
    uint256 saveCooldown = 1 days;
    uint256 keeperPayout = 0.5 ether;
    uint256 minKeeperPayoutValue = 0.01 ether;
    uint256 payoutToSAFESize = 40;
    uint256 defaultDesiredCollateralizationRatio = 200;
    uint256 minDesiredCollateralizationRatio = 155;

    // Core system params
    uint256 goldPrice = 3.75 ether;
    uint256 minCRatio = 1.5 ether;
    uint256 goldToMint = 5000 ether;
    uint256 goldCeiling = 1000 ether;
    uint256 goldSafetyPrice = 1 ether;
    uint256 goldLiquidationPenalty = 1 ether;

    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        // System coin
        systemCoin = new Coin("RAI", "RAI", 1);
        systemCoin.mint(address(this), systemCoinsToMint);
        systemCoinOracle = new Feed(systemCoinPrice, true);

        // Compound setup
        compoundSysCoinOracle = new CompoundPriceOracle();
        compoundSysCoinOracle.setPrice(systemCoinPrice);

        interestRateModel = new WhitePaperInterestRateModel(baseRatePerYear, multiplierPerYear);
        unitroller  = new Unitroller();
        comptroller = new ComptrollerG2();

        unitroller._setPendingImplementation(address(comptroller));
        comptroller._become(unitroller);

        comptroller._setLiquidationIncentive(liquidationIncentive);
        comptroller._setCloseFactor(closeFactor);
        comptroller._setMaxAssets(maxAssets);
        comptroller._setPriceOracle(compoundSysCoinOracle);

        cRAI = new CErc20();
        cRAI.initialize(
            address(systemCoin),
            comptroller,
            interestRateModel,
            exchangeRate,
            cTokenName,
            cTokenSymbol,
            cTokenDecimals
        );
        comptroller._supportMarket(cRAI);

        // Core system
        safeEngine = new TestSAFEEngine();

        goldFSM    = new Feed(goldPrice, true);
        goldMedian = new Feed(goldPrice, true);
        goldFSM.updatePriceSource(address(goldMedian));

        oracleRelayer = new OracleRelayer(address(safeEngine));
        oracleRelayer.modifyParameters("redemptionPrice", ray(systemCoinPrice));
        oracleRelayer.modifyParameters("gold", "orcl", address(goldFSM));
        oracleRelayer.modifyParameters("gold", "safetyCRatio", ray(minCRatio));
        oracleRelayer.modifyParameters("gold", "liquidationCRatio", ray(minCRatio));
        safeEngine.addAuthorization(address(oracleRelayer));

        accountingEngine = new TestAccountingEngine(
          address(safeEngine), address(0x1), address(0x2)
        );
        safeEngine.addAuthorization(address(accountingEngine));

        taxCollector = new TaxCollector(address(safeEngine));
        taxCollector.initializeCollateralType("gold");
        taxCollector.modifyParameters("primaryTaxReceiver", address(accountingEngine));
        safeEngine.addAuthorization(address(taxCollector));

        liquidationEngine = new LiquidationEngine(address(safeEngine));
        liquidationEngine.modifyParameters("accountingEngine", address(accountingEngine));

        safeEngine.addAuthorization(address(liquidationEngine));
        accountingEngine.addAuthorization(address(liquidationEngine));

        gold = new DSToken("GOLD", 'GOLD');
        gold.mint(goldToMint);

        safeEngine.initializeCollateralType("gold");

        collateralJoin = new BasicCollateralJoin(address(safeEngine), "gold", address(gold));

        coinJoin = new CoinJoin(address(safeEngine), address(systemCoin));
        systemCoin.addAuthorization(address(coinJoin));

        safeEngine.addAuthorization(address(collateralJoin));

        safeEngine.modifyParameters("gold", "safetyPrice", ray(goldSafetyPrice));
        safeEngine.modifyParameters("gold", "debtCeiling", rad(goldCeiling));
        safeEngine.modifyParameters("globalDebtCeiling", rad(goldCeiling));

        collateralAuctionHouse = new EnglishCollateralAuctionHouse(address(safeEngine), address(liquidationEngine), "gold");
        collateralAuctionHouse.addAuthorization(address(liquidationEngine));

        liquidationEngine.addAuthorization(address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("gold", "collateralAuctionHouse", address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("gold", "liquidationPenalty", goldLiquidationPenalty);

        safeEngine.addAuthorization(address(collateralAuctionHouse));
        safeEngine.approveSAFEModification(address(collateralAuctionHouse));

        safeManager = new GebSafeManager(address(safeEngine));
        oracleRelayer.updateCollateralPrice("gold");

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);
        cRatioSetter = new SaviourCRatioSetter(address(oracleRelayer), address(safeManager));
        cRatioSetter.setDefaultCRatio("gold", defaultDesiredCollateralizationRatio);

        saviour = new CompoundSystemCoinSafeSaviour(
            address(coinJoin),
            address(cRatioSetter),
            address(systemCoinOracle),
            address(liquidationEngine),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(cRAI),
            keeperPayout,
            minKeeperPayoutValue
        );
        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        me    = address(this);
        alice = new FakeUser();
    }

    // --- Math ---
    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }
    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }

    // --- Default actions/scenarios ---
    function default_create_liquidatable_position(uint256 desiredCRatio, uint256 liquidatableCollateralPrice) internal returns (address) {
        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("gold", safeHandler), address(saviour));

        goldMedian.updateCollateralPrice(liquidatableCollateralPrice);
        goldFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("gold");

        return safeHandler;
    }
    function default_save(uint256 safe, address safeHandler, uint desiredCRatio) internal {
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("gold", safeHandler), address(saviour));

        goldMedian.updateCollateralPrice(3 ether);
        goldFSM.updateCollateralPrice(3 ether);
        oracleRelayer.updateCollateralPrice("gold");

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        uint256 oldCTokenSupply = cRAI.totalSupply();

        assertTrue(saviour.keeperPayoutExceedsMinValue());
        assertTrue(saviour.canSave("gold", safeHandler));

        liquidationEngine.modifyParameters("gold", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("gold", "liquidationPenalty", 1.1 ether);

        uint256 preSaveKeeperBalance = systemCoin.balanceOf(address(this));
        uint auction = liquidationEngine.liquidateSAFE("gold", safeHandler);

        assertEq(auction, 0);
        assertEq(systemCoin.balanceOf(address(this)) - preSaveKeeperBalance, saviour.keeperPayout());
        assertTrue(oldCTokenSupply - cRAI.totalSupply() > 0);
        assertTrue(cRAI.totalSupply() > 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("gold", safeHandler);
        assertEq(lockedCollateral * 3E27 * 100 / (generatedDebt * oracleRelayer.redemptionPrice()), desiredCRatio);
    }
    function default_second_save(uint256 safe, address safeHandler, uint desiredCRatio) internal {
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, desiredCRatio);

        goldMedian.updateCollateralPrice(2.5 ether);
        goldFSM.updateCollateralPrice(2.5 ether);
        oracleRelayer.updateCollateralPrice("gold");

        uint256 oldCTokenSupply = cRAI.totalSupply();

        assertTrue(saviour.keeperPayoutExceedsMinValue());
        assertTrue(saviour.canSave("gold", safeHandler));

        liquidationEngine.modifyParameters("gold", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("gold", "liquidationPenalty", 1.1 ether);

        uint256 preSaveKeeperBalance = systemCoin.balanceOf(address(this));
        uint auction = liquidationEngine.liquidateSAFE("gold", safeHandler);

        assertEq(auction, 0);
        assertEq(systemCoin.balanceOf(address(this)) - preSaveKeeperBalance, saviour.keeperPayout());
        assertTrue(oldCTokenSupply - cRAI.totalSupply() > 0);
        assertTrue(cRAI.totalSupply() > 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("gold", safeHandler);
        assertEq(lockedCollateral * 2.5E27 * 100 / (generatedDebt * oracleRelayer.redemptionPrice()), desiredCRatio);
    }
    function default_liquidate_safe(address safeHandler) internal {
        goldMedian.updateCollateralPrice(3 ether);
        goldFSM.updateCollateralPrice(3 ether);
        oracleRelayer.updateCollateralPrice("gold");

        liquidationEngine.modifyParameters("gold", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("gold", "liquidationPenalty", 1.1 ether);

        uint auction = liquidationEngine.liquidateSAFE("gold", safeHandler);
        // the full SAFE is liquidated
        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("gold", me);
        assertEq(lockedCollateral, 0);
        assertEq(generatedDebt, 0);
        // all debt goes to the accounting engine
        assertEq(accountingEngine.totalQueuedDebt(), rad(defaultTokenAmount));
        // auction is for all collateral
        (,uint amountToSell,,,,,, uint256 amountToRaise) = collateralAuctionHouse.bids(auction);
        assertEq(amountToSell, defaultCollateralAmount);
        assertEq(amountToRaise, rad(110 ether));
    }
    function default_create_liquidatable_position_deposit_cover(uint256 desiredCRatio, uint256 liquidatableCollateralPrice) internal returns (address) {
        // Create position
        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("gold", safeHandler), address(saviour));

        goldMedian.updateCollateralPrice(liquidatableCollateralPrice);
        goldFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("gold");

        // Deposit cover
        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        uint256 totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply > 0);
        assertEq(cRAI.balanceOf(address(saviour)), totalSupply);
        assertEq(systemCoin.balanceOf(address(cRAI)), defaultTokenAmount);
        assertEq(saviour.cTokenCover("gold", safeHandler), totalSupply);

        return safeHandler;
    }
    function default_create_position_deposit_cover() internal returns (uint, address, uint) {
        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        uint256 totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply > 0);
        assertEq(cRAI.balanceOf(address(saviour)), totalSupply);
        assertEq(systemCoin.balanceOf(address(cRAI)), defaultTokenAmount);
        assertEq(saviour.cTokenCover("gold", safeHandler), totalSupply);

        return (safe, safeHandler, totalSupply);
    }
    function default_modify_collateralization(uint256 safe, address safeHandler) internal {
        gold.approve(address(collateralJoin));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount));
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertEq(saviour.keeperPayout(), keeperPayout);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);

        assertEq(address(saviour.coinJoin()), address(coinJoin));
        assertEq(address(saviour.cRatioSetter()), address(cRatioSetter));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.systemCoin()), address(systemCoin));
        assertEq(address(saviour.safeEngine()), address(safeEngine));
        assertEq(address(saviour.safeManager()), address(safeManager));
        assertEq(address(saviour.saviourRegistry()), address(saviourRegistry));
        assertEq(address(saviour.cToken()), address(cRAI));
    }
    function testFail_modifyParameters_uint_unauthorized() public {
        alice.doModifyParameters(saviour, "keeperPayout", 5);
    }
    function test_modifyParameters_uint() public {
        saviour.modifyParameters("keeperPayout", 5);
        assertEq(saviour.keeperPayout(), 5);
    }
    function testFail_modifyParameters_address_unauthorized() public {
        systemCoinOracle = new Feed(systemCoinPrice, true);
        alice.doModifyParameters(saviour, "systemCoinOrcl", address(systemCoinOracle));
    }
    function test_modifyParameters_address() public {
        systemCoinOracle = new Feed(systemCoinPrice, true);
        saviour.modifyParameters("systemCoinOrcl", address(systemCoinOracle));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
    }
    function testFail_deposit_liq_engine_not_approved() public {
        liquidationEngine.disconnectSAFESaviour(address(saviour));

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);
    }
    function testFail_deposit_null_sys_coin_amount() public {
        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", safe, 0);
    }
    function testFail_deposit_inexistent_safe() public {
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);
    }
    function test_deposit_no_prior_compound_liquidity() public {
        default_create_position_deposit_cover();
    }
    function test_deposit_twice() public {
        (uint safe, address safeHandler, ) = default_create_position_deposit_cover();

        // Second deposit
        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);

        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        uint256 totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply > 0);
        assertEq(cRAI.balanceOf(address(saviour)), totalSupply);
        assertEq(systemCoin.balanceOf(address(cRAI)), defaultTokenAmount * 2);
        assertEq(saviour.cTokenCover("gold", safeHandler), totalSupply);
    }
    function test_deposit_after_everything_withdrawn() public {
        (uint safe, address safeHandler, uint totalSupply) = default_create_position_deposit_cover();

        // Withdraw
        alice.doWithdraw(saviour, "gold", safe, totalSupply);

        totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply == 0);
        assertEq(cRAI.balanceOf(address(saviour)), 0);
        assertEq(systemCoin.balanceOf(address(cRAI)), 0);
        assertEq(saviour.cTokenCover("gold", safeHandler), 0);

        // Second deposit
        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply > 0);
        assertEq(cRAI.balanceOf(address(saviour)), totalSupply);
        assertEq(systemCoin.balanceOf(address(cRAI)), defaultTokenAmount);
        assertEq(saviour.cTokenCover("gold", safeHandler), totalSupply);
    }
    function testFail_withdraw_unauthorized() public {
        (uint safe, , ) = default_create_position_deposit_cover();

        // Withdraw by unauthed
        FakeUser bob = new FakeUser();
        bob.doWithdraw(saviour, "gold", safe, defaultTokenAmount);
    }
    function testFail_withdraw_more_than_deposited() public {
        (uint safe, , uint totalSupply) = default_create_position_deposit_cover();

        // Withdraw
        alice.doWithdraw(saviour, "gold", safe, totalSupply + 1);
    }
    function testFail_withdraw_null() public {
        (uint safe, , ) = default_create_position_deposit_cover();

        // Withdraw
        alice.doWithdraw(saviour, "gold", safe, 0);
    }
    function test_withdraw() public {
        (uint safe, address safeHandler, uint totalSupply) = default_create_position_deposit_cover();

        // Withdraw
        alice.doWithdraw(saviour, "gold", safe, totalSupply);

        totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply == 0);
        assertEq(cRAI.balanceOf(address(saviour)), 0);
        assertEq(systemCoin.balanceOf(address(cRAI)), 0);
        assertEq(saviour.cTokenCover("gold", safeHandler), 0);
    }
    function test_withdraw_twice() public {
        (uint safe, address safeHandler, uint totalSupply) = default_create_position_deposit_cover();

        // Withdraw first time
        alice.doWithdraw(saviour, "gold", safe, totalSupply / 2);

        assertTrue(totalSupply > 0);
        assertEq(cRAI.balanceOf(address(saviour)), totalSupply / 2);
        assertEq(systemCoin.balanceOf(address(cRAI)), defaultTokenAmount / 2);
        assertEq(saviour.cTokenCover("gold", safeHandler), totalSupply / 2);

        // Withdraw second time
        alice.doWithdraw(saviour, "gold", safe, totalSupply / 2);

        totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply == 0);
        assertEq(cRAI.balanceOf(address(saviour)), 0);
        assertEq(systemCoin.balanceOf(address(cRAI)), 0);
        assertEq(saviour.cTokenCover("gold", safeHandler), 0);
    }
    function test_keeperPayoutExceedsMinValue_valid_orcl_result_true() public {
        assertTrue(saviour.keeperPayoutExceedsMinValue());
    }
    function test_keeperPayoutExceedsMinValue_valid_orcl_result_false() public {
        saviour.modifyParameters("minKeeperPayoutValue", minKeeperPayoutValue * 10000);
        assertTrue(!saviour.keeperPayoutExceedsMinValue());
    }
    function test_keeperPayoutExceedsMinValue_invalid_orcl_result() public {
        systemCoinOracle.changeValidity();
        assertTrue(!saviour.keeperPayoutExceedsMinValue());
    }
    function test_keeperPayoutExceedsMinValue_null_orcl_result() public {
        systemCoinOracle.updateCollateralPrice(0);
        assertTrue(!saviour.keeperPayoutExceedsMinValue());
    }
    function test_getKeeperPayoutValue_valid_orcl_result_true() public {
        assertEq(saviour.getKeeperPayoutValue(), 0.5 ether);
    }
    function test_getKeeperPayoutValue_invalid_orcl_result() public {
        systemCoinOracle.changeValidity();
        assertEq(saviour.getKeeperPayoutValue(), 0);
    }
    function test_getKeeperPayoutValue_null_orcl_result() public {
        systemCoinOracle.updateCollateralPrice(0);
        assertEq(saviour.getKeeperPayoutValue(), 0);
    }
    function test_tokenAmountUsedToSave_col_invalid_price() public {
        address safeHandler = default_create_liquidatable_position(250, 3 ether);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);

        goldFSM.changeValidity();
        assertEq(saviour.tokenAmountUsedToSave("gold", safeHandler), uint(-1));
    }
    function test_tokenAmountUsedToSave_null_price() public {
        address safeHandler = default_create_liquidatable_position(200, 1 ether);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);

        goldFSM.updateCollateralPrice(0);
        assertEq(saviour.tokenAmountUsedToSave("gold", safeHandler), uint(-1));
    }
    function test_tokenAmountUsedToSave() public {
        address safeHandler = default_create_liquidatable_position(400, 1 ether);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);

        assertEq(saviour.tokenAmountUsedToSave("gold", safeHandler), 90 ether);
    }
    function test_tokenAmountUsedToSave_tiny_redemption_price() public {
        oracleRelayer.modifyParameters("redemptionPrice", ray(0.000001 ether));
        address safeHandler = default_create_liquidatable_position(400, 1 ether);

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);

        assertEq(saviour.tokenAmountUsedToSave("gold", safeHandler), 99.99999 ether);
    }
    function test_canSave_invalid_collateral_price() public {
        address safeHandler = default_create_liquidatable_position_deposit_cover(250, 1 ether);
        goldFSM.changeValidity();
        assertTrue(!saviour.canSave("gold", safeHandler));
    }
    function test_canSave_null_collateral_price() public {
        address safeHandler = default_create_liquidatable_position_deposit_cover(250, 1 ether);
        goldFSM.updateCollateralPrice(0);
        assertTrue(!saviour.canSave("gold", safeHandler));
    }
    function test_canSave_null_safe_debt() public {
        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        assertTrue(!saviour.canSave("gold", safeHandler));
    }
    function test_canSave_insufficient_ctoken_cover() public {
        saviour.modifyParameters("keeperPayout", 5000 ether);
        address safeHandler = default_create_liquidatable_position_deposit_cover(250, 1 ether);
        assertTrue(!saviour.canSave("gold", safeHandler));
    }
    function test_canSave() public {
        address safeHandler = default_create_liquidatable_position_deposit_cover(250, 1 ether);
        assertTrue(saviour.canSave("gold", safeHandler));
    }
    function test_canSave_tiny_redemption_price() public {
        oracleRelayer.modifyParameters("redemptionPrice", ray(0.000001 ether));
        address safeHandler = default_create_liquidatable_position_deposit_cover(250, 1 ether);

        // Deposit even more cover
        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", 1, defaultTokenAmount);

        assertTrue(saviour.canSave("gold", safeHandler));
    }
    function testFail_saveSAFE_invalid_caller() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, 200);

        goldMedian.updateCollateralPrice(3 ether);
        goldFSM.updateCollateralPrice(3 ether);
        oracleRelayer.updateCollateralPrice("gold");

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        liquidationEngine.modifyParameters("gold", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("gold", "liquidationPenalty", 1.1 ether);

        saviour.saveSAFE(address(this), "gold", safeHandler);
    }
    function test_saveSAFE_small_payout() public {
        saviour.modifyParameters("keeperPayout", 5000 ether);

        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, 155);
        assertEq(liquidationEngine.chosenSAFESaviour("gold", safeHandler), address(saviour));

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount);

        default_liquidate_safe(safeHandler);
        assertEq(saviourRegistry.lastSaveTime("gold", safeHandler), 0);
    }
    function test_saveSAFE_insufficient_ctoken_coverage() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "gold", safe, 900);
        assertEq(liquidationEngine.chosenSAFESaviour("gold", safeHandler), address(saviour));

        safeEngine.mint(safeHandler, rad(defaultTokenAmount));
        systemCoin.mint(address(alice), defaultTokenAmount);
        alice.doDeposit(saviour, systemCoin, "gold", safe, defaultTokenAmount / 10);

        default_liquidate_safe(safeHandler);
        assertEq(saviourRegistry.lastSaveTime("gold", safeHandler), 0);
    }
    function test_saveSAFE_high_cratio() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler, 999);

        assertEq(saviourRegistry.lastSaveTime("gold", safeHandler), now);
    }
    function test_saveSAFE_withdraw() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler, 200);

        assertEq(saviourRegistry.lastSaveTime("gold", safeHandler), now);

        // Withdraw
        alice.doWithdraw(saviour, "gold", safe, saviour.cTokenCover("gold", safeHandler));

        uint256 totalSupply = cRAI.totalSupply();
        assertTrue(totalSupply == 0);
        assertEq(cRAI.balanceOf(address(saviour)), 0);
        assertEq(systemCoin.balanceOf(address(cRAI)), 0);
        assertEq(saviour.cTokenCover("gold", safeHandler), 0);
    }
    function testFail_saveSAFE_twice_in_row_same_keeper() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler, 200);

        hevm.warp(now + 1);
        default_save(safe, safeHandler, 200);
    }
    function test_saveSAFE_twice_large_delay() public {
        hevm.warp(now + 1);

        uint safe = alice.doOpenSafe(safeManager, "gold", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler, 155);

        hevm.warp(now + saviourRegistry.saveCooldown() + 1);
        default_second_save(safe, safeHandler, 200);

        assertEq(saviourRegistry.lastSaveTime("gold", safeHandler), now);
    }
}
