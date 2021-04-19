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
        DSToken systemCoin,
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

    function doSetDesiredCollateralizationRatio(
        CompoundSystemCoinSafeSaviour saviour,
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
    uint256 systemCoinPrice = 3 ether;

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
    uint256 minDesiredCollateralizationRatio = 200;

    // Core system params
    uint256 goldPrice = 3.75 ether;
    uint256 minCRatio = 1.5 ether;
    uint256 goldToMint = 1000 ether;
    uint256 goldCeiling = 1000 ether;
    uint256 goldSafetyPrice = 1 ether;
    uint256 goldLiquidationPenalty = 1 ether;

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

    function test_setup() public {

    }
    function testFail_modifyParameters_uint_unauthorized() public {

    }
    function test_modifyParameters_uint() public {

    }
    function testFail_modifyParameters_address_unauthorized() public {

    }
    function test_modifyParameters_address() public {

    }
    function testFail_deposit_liq_engine_not_approved() public {

    }
    function testFail_deposit_null_sys_coin_amount() public {

    }
    function testFail_deposit_null_default_cratio() public {

    }
    function testFail_deposit_inexistent_safe() public {

    }
    function test_deposit_no_prior_compound_liquidity() public {

    }
    function test_deposit_twice() public {

    }
    function test_deposit_when_borrow_activity() public {

    }
    function test_deposit_after_everything_withdrawn() public {

    }
    function testFail_withdraw_unauthorized() public {

    }
    function testFail_withdraw_more_than_deposited() public {

    }
    function testFail_withdraw_null() public {

    }
    function testFail_withdraw_everything_lent_is_borrowed() public {

    }
    function test_withdraw() public {

    }
    function test_withdraw_after_earning_interest() public {

    }
    function test_withdraw_twice() public {

    }
    function test_keeperPayoutExceedsMinValue_valid_orcl_result() public {

    }
    function test_keeperPayoutExceedsMinValue_invalid_orcl_result() public {

    }
    function test_keeperPayoutExceedsMinValue_null_orcl_result() public {

    }
    function test_getKeeperPayoutValue_valid_orcl_result() public {

    }
    function test_getKeeperPayoutValue_invalid_orcl_result() public {

    }
    function test_getKeeperPayoutValue_null_orcl_result() public {

    }
    function test_tokenAmountUsedToSave_invalid_price() public {

    }
    function test_tokenAmountUsedToSave_null_price() public {

    }
    function test_tokenAmountUsedToSave_null_default_cratio() public {

    }
    function test_tokenAmountUsedToSave_null_safe_debt() public {

    }
    function test_tokenAmountUsedToSave() public {

    }
    function test_tokenAmountUsedToSave_custom_desired_cratio() public {

    }
    function test_tokenAmountUsedToSave_tiny_redemption_price() public {

    }
    function test_tokenAmountUsedToSave_after_accrued_ctoken_interest() public {

    }
    function test_canSave_invalid_price() public {

    }
    function test_canSave_null_price() public {

    }
    function test_canSave_null_default_cratio() public {

    }
    function test_canSave_null_safe_debt() public {

    }
    function test_canSave() public {

    }
    function test_canSave_custom_desired_cratio() public {

    }
    function test_canSave_tiny_redemption_price() public {

    }
    function test_canSave_after_accrued_ctoken_interest() public {

    }
    function testFail_saveSAFE_invalid_caller() public {

    }
    function testFail_saveSAFE_invalid_caller() public {

    }
    function testFail_saveSAFE_small_payout() public {

    }
    function testFail_invalid_token_amount_used() public {

    }
    function testFail_insufficient_ctoken_cover() public {

    }
    function test_saveSAFE_high_cratio() public {

    }
    function test_saveSAFE_after_accrued_interest() public {

    }
    function test_saveSAFE_withdraw() public {

    }
}
