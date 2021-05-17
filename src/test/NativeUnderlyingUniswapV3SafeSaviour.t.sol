pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
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

import {SaviourCRatioSetter} from "../SaviourCRatioSetter.sol";
import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import { GebUniswapV3TwoTrancheManager } from "geb-uni-v3-manager/GebUniswapV3TwoTrancheManager.sol";
import { GebUniswapV3ManagerBase, GebUniswapV3ManagerBaseTest } from "geb-uni-v3-manager/test/GebUniswapV3ManagerBaseTest.t.sol";

import "../integrations/uniswap/liquidity-managers/UniswapV3LiquidityManager.sol";

import "../saviours/NativeUnderlyingUniswapV3SafeSaviour.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
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

// Users
contract FakeUser {
    function doModifyParameters(
      NativeUnderlyingUniswapV3SafeSaviour saviour,
      bytes32 parameter,
      uint256 data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
      NativeUnderlyingUniswapV3SafeSaviour saviour,
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
        NativeUnderlyingUniswapV3SafeSaviour saviour,
        DSToken lpToken,
        uint256 safeID,
        uint256 tokenAmount
    ) public {
        lpToken.approve(address(saviour), tokenAmount);
        saviour.deposit(safeID, tokenAmount);
    }

    function doWithdraw(
        NativeUnderlyingUniswapV3SafeSaviour saviour,
        uint256 safeID,
        uint256 lpTokenAmount,
        address dst
    ) public {
        saviour.withdraw(safeID, lpTokenAmount, dst);
    }

    function doGetReserves(
        NativeUnderlyingUniswapV3SafeSaviour saviour,
        uint256 safeID,
        address dst
    ) public {
        saviour.getReserves(safeID, dst);
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

contract NativeUnderlyingUniswapV3SafeSaviourTest is GebUniswapV3ManagerBaseTest {
    GebUniswapV3TwoTrancheManager uniswapManager;
    UniswapV3LiquidityManager liquidityManager;

    TestSAFEEngine safeEngine;
    AccountingEngine accountingEngine;
    LiquidationEngine liquidationEngine;
    OracleRelayer oracleRelayer;
    TaxCollector taxCollector;

    BasicCollateralJoin collateralJoin;

    CoinJoin coinJoin;
    CoinJoin systemCoinJoin;

    EnglishCollateralAuctionHouse collateralAuctionHouse;

    GebSafeManager safeManager;

    NativeUnderlyingUniswapV3SafeSaviour saviour;
    SaviourCRatioSetter cRatioSetter;
    SAFESaviourRegistry saviourRegistry;

    MockMedianizer systemCoinOracle;
    MockMedianizer ethFSM;
    MockMedianizer ethMedian;

    FakeUser alice;

    address me;

    // Params
    uint256 tokenAmountMinted = 100000 ether;

    // Uniswap manager related params
    uint256 threshold1 = 200040; // 20%
    uint256 threshold2 = 50040;  // 5%
    uint128 ratio1 = 50;         // 36%
    uint128 ratio2 = 50;         // 36%
    uint256 delay = 120 minutes; // 10 minutes

    // Saviour params
    bool isSystemCoinToken0;
    uint256 saveCooldown = 1 days;
    uint256 minKeeperPayoutValue = 1000 ether;
    uint256 defaultDesiredCollateralizationRatio = 200;
    uint256 minDesiredCollateralizationRatio = 155;

    // Core system params
    uint256 minCRatio = 1.5 ether;
    uint256 ethToMint = 5000 ether;
    uint256 ethCeiling = uint(-1);
    uint256 ethFloor = 10 ether;
    uint256 ethLiquidationPenalty = 1 ether;

    uint256 defaultLiquidityMultiplier = 50;
    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;

    function setUp() override public {
        // Setup Uniswap V3 + manager
        super.setUp();

        uniswapManager = new GebUniswapV3TwoTrancheManager("Geb-Uniswap-Manager", "GUM", address(testRai), uint128(delay), threshold1, threshold2, ratio1, ratio2, address(pool), oracle, pv);
        manager_base   = GebUniswapV3ManagerBase(uniswapManager);

        initialPoolPrice = helper_getRebalancePrice();
        pool.initialize(initialPoolPrice);

        helper_addWhaleLiquidity();

        isSystemCoinToken0 = (address(token0) == address(testRai)) ? true : false;

        // Setup token oracles
        (uint initRAIUSDPrice, uint initETHUSDPrice) = uniswapManager.getPrices();
        systemCoinOracle = new MockMedianizer(initRAIUSDPrice, true);

        ethFSM    = new MockMedianizer(initETHUSDPrice, true);
        ethMedian = new MockMedianizer(initETHUSDPrice, true);
        ethFSM.updatePriceSource(address(ethMedian));

        // Core system
        safeEngine = new TestSAFEEngine();
        safeEngine.initializeCollateralType("eth");
        safeEngine.mint(address(this), rad(tokenAmountMinted));

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

        collateralJoin = new BasicCollateralJoin(address(safeEngine), "eth", address(testWeth));

        coinJoin = new CoinJoin(address(safeEngine), address(testRai));
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

        // Liquidity manager
        liquidityManager = new UniswapV3LiquidityManager(address(uniswapManager));

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);
        cRatioSetter = new SaviourCRatioSetter(address(oracleRelayer), address(safeManager));
        cRatioSetter.setDefaultCRatio("eth", defaultDesiredCollateralizationRatio);

        saviour = new NativeUnderlyingUniswapV3SafeSaviour(
            isSystemCoinToken0,
            address(coinJoin),
            address(collateralJoin),
            address(cRatioSetter),
            address(systemCoinOracle),
            address(liquidationEngine),
            address(taxCollector),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(uniswapManager),
            address(uniswapManager),
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
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    function test_setup() public {

    }
}
