pragma solidity ^0.6.7;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import {SAFEEngine} from "geb/SAFEEngine.sol";
import {Coin} from "geb/Coin.sol";
import {LiquidationEngine} from "geb/LiquidationEngine.sol";
import {AccountingEngine} from "geb/AccountingEngine.sol";
import {TaxCollector} from "geb/TaxCollector.sol";
import "geb/BasicTokenAdapters.sol";
import {OracleRelayer} from "geb/OracleRelayer.sol";
import {EnglishCollateralAuctionHouse} from "geb/CollateralAuctionHouse.sol";
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import "../integrations/curve/CurvePoolV2Mock.sol";
import {CurveV2MaxSafeSaviour} from "../saviours/CurveV2MaxSafeSaviour.sol";

abstract contract Hevm {
    function warp(uint256) public virtual;
}

// --- Median Contracts ---
contract MockMedianizer {
    uint256 public price;
    bool public validPrice;
    uint256 public lastUpdateTime;
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
    uint256 constant RAY = 10**27;

    constructor() public {}

    function mint(address usr, uint256 wad) public {
        coinBalance[usr] += wad * RAY;
        globalDebt += wad * RAY;
    }

    function balanceOf(address usr) public view returns (uint256) {
        return uint256(coinBalance[usr] / RAY);
    }
}

// Users
contract FakeUser {
    function doModifyParameters(
        CurveV2MaxSafeSaviour saviour,
        bytes32 parameter,
        uint256 data
    ) public {
        saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
        CurveV2MaxSafeSaviour saviour,
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
        uint256 safe,
        address usr,
        uint256 ok
    ) public {
        manager.allowSAFE(safe, usr, ok);
    }

    function doHandlerAllow(
        GebSafeManager manager,
        address usr,
        uint256 ok
    ) public {
        manager.allowHandler(usr, ok);
    }

    function doTransferSAFEOwnership(
        GebSafeManager manager,
        uint256 safe,
        address dst
    ) public {
        manager.transferSAFEOwnership(safe, dst);
    }

    function doModifySAFECollateralization(
        GebSafeManager manager,
        uint256 safe,
        int256 deltaCollateral,
        int256 deltaDebt
    ) public {
        manager.modifySAFECollateralization(safe, deltaCollateral, deltaDebt);
    }

    function doApproveSAFEModification(SAFEEngine safeEngine, address usr)
        public
    {
        safeEngine.approveSAFEModification(usr);
    }

    function doSAFEEngineModifySAFECollateralization(
        SAFEEngine safeEngine,
        bytes32 collateralType,
        address safe,
        address collateralSource,
        address debtDst,
        int256 deltaCollateral,
        int256 deltaDebt
    ) public {
        safeEngine.modifySAFECollateralization(
            collateralType,
            safe,
            collateralSource,
            debtDst,
            deltaCollateral,
            deltaDebt
        );
    }

    function doProtectSAFE(
        GebSafeManager manager,
        uint256 safe,
        address liquidationEngine,
        address saviour
    ) public {
        manager.protectSAFE(safe, liquidationEngine, saviour);
    }

    function doDeposit(
        CurveV2MaxSafeSaviour saviour,
        DSToken collateral,
        bytes32 collateralType,
        uint256 safe,
        uint256 amount
    ) public {
        collateral.approve(address(saviour), amount);
        saviour.deposit(collateralType, safe, amount);
    }

    function doWithdraw(
        CurveV2MaxSafeSaviour saviour,
        bytes32 collateralType,
        uint256 safe,
        uint256 amount,
        address dst
    ) public {
        saviour.withdraw(collateralType, safe, amount, dst);
    }

    function doGetReserves(
        CurveV2MaxSafeSaviour saviour,
        uint256 safeID,
        address[] calldata tokens,
        address dst
    ) external {
        saviour.getReserves(safeID, tokens, dst);
    }

    function doGetReserves(
        CurveV2MaxSafeSaviour saviour,
        uint256 safeID,
        address token,
        address dst
    ) external {
        saviour.getReserves(safeID, token, dst);
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

contract CurveV2MaxSafeSaviourTest is DSTest {
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
    DSToken lpToken;
    DSToken secondCurveToken;

    CurvePoolV2Mock poolMock;
    CurveV2MaxSafeSaviour saviour;

    SAFESaviourRegistry saviourRegistry;

    FakeUser alice;
    address me;

    // General params
    uint256 initTokenAmount = 100000 ether;
    uint256 initETHUSDPrice = 250 * 10**18;
    uint256 initRAIUSDPrice = 4.242 * 10**18;

    // Curve pool params
    address[] coins;
    uint256[] coinAmounts;

    uint256 defaultCoinAmount = 100E18;
    uint256 defaultLpTokenToDeposit = 500E18;

    // Saviour parameters
    uint256 saveCooldown = 1 days;
    uint256 minKeeperPayoutValue = 1000 ether;

    // Core system params
    uint256 minCRatio = 1.5 ether;
    uint256 ethToMint = 5000 ether;
    uint256 ethCeiling = uint256(-1);
    uint256 ethFloor = 10 ether;
    uint256 ethLiquidationPenalty = 1 ether;

    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;

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

        ethFSM = new MockMedianizer(initETHUSDPrice, true);
        ethMedian = new MockMedianizer(initETHUSDPrice, true);
        ethFSM.updatePriceSource(address(ethMedian));

        oracleRelayer = new OracleRelayer(address(safeEngine));
        oracleRelayer.modifyParameters("redemptionPrice", ray(initRAIUSDPrice));
        oracleRelayer.modifyParameters("eth", "orcl", address(ethFSM));
        oracleRelayer.modifyParameters("eth", "safetyCRatio", ray(minCRatio));
        oracleRelayer.modifyParameters(
            "eth",
            "liquidationCRatio",
            ray(minCRatio)
        );

        safeEngine.addAuthorization(address(oracleRelayer));
        oracleRelayer.updateCollateralPrice("eth");

        accountingEngine = new AccountingEngine(
            address(safeEngine),
            address(0x1),
            address(0x2)
        );
        safeEngine.addAuthorization(address(accountingEngine));

        taxCollector = new TaxCollector(address(safeEngine));
        taxCollector.initializeCollateralType("eth");
        taxCollector.modifyParameters(
            "primaryTaxReceiver",
            address(accountingEngine)
        );
        taxCollector.modifyParameters(
            "eth",
            "stabilityFee",
            1000000564701133626865910626
        ); // 5% / day
        safeEngine.addAuthorization(address(taxCollector));

        liquidationEngine = new LiquidationEngine(address(safeEngine));
        liquidationEngine.modifyParameters(
            "accountingEngine",
            address(accountingEngine)
        );

        safeEngine.addAuthorization(address(liquidationEngine));
        accountingEngine.addAuthorization(address(liquidationEngine));

        weth = new WETH9_();
        weth.deposit{value: initTokenAmount}();

        collateralJoin = new BasicCollateralJoin(
            address(safeEngine),
            "eth",
            address(weth)
        );

        coinJoin = new CoinJoin(address(safeEngine), address(systemCoin));
        systemCoin.addAuthorization(address(coinJoin));
        safeEngine.transferInternalCoins(
            address(this),
            address(coinJoin),
            safeEngine.coinBalance(address(this))
        );

        safeEngine.addAuthorization(address(collateralJoin));

        safeEngine.modifyParameters("eth", "debtCeiling", rad(ethCeiling));
        safeEngine.modifyParameters("globalDebtCeiling", rad(ethCeiling));
        safeEngine.modifyParameters("eth", "debtFloor", rad(ethFloor));

        collateralAuctionHouse = new EnglishCollateralAuctionHouse(
            address(safeEngine),
            address(liquidationEngine),
            "eth"
        );
        collateralAuctionHouse.addAuthorization(address(liquidationEngine));

        liquidationEngine.addAuthorization(address(collateralAuctionHouse));
        liquidationEngine.modifyParameters(
            "eth",
            "collateralAuctionHouse",
            address(collateralAuctionHouse)
        );
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationPenalty",
            ethLiquidationPenalty
        );

        safeEngine.addAuthorization(address(collateralAuctionHouse));
        safeEngine.approveSAFEModification(address(collateralAuctionHouse));

        safeManager = new GebSafeManager(address(safeEngine));
        oracleRelayer.updateCollateralPrice("eth");

        // Curve setup
        lpToken = new DSToken("LP", "LP");
        secondCurveToken = new DSToken("CRV-2-TOKEN", "CRV-2-TOKEN");

        coins.push(address(systemCoin));
        coins.push(address(secondCurveToken));
        coins.push(address(weth));

        coinAmounts.push(defaultCoinAmount * 100);
        coinAmounts.push(defaultCoinAmount * 100);
        coinAmounts.push(defaultCoinAmount * 100);

        poolMock = new CurvePoolV2Mock(coinAmounts, coins, address(lpToken));

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);

        saviour = new CurveV2MaxSafeSaviour(
            address(coinJoin),
            address(collateralJoin),
            address(systemCoinOracle),
            address(liquidationEngine),
            address(taxCollector),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(poolMock),
            minKeeperPayoutValue
        );
        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        me = address(this);
        alice = new FakeUser();

        // Mint Curve related tokens
        lpToken.mint(address(alice), initTokenAmount * initTokenAmount);
        lpToken.mint(address(this), initTokenAmount * initTokenAmount);
        systemCoin.mint(address(poolMock), initTokenAmount * 100);
        systemCoin.mint(address(alice), initTokenAmount);
        secondCurveToken.mint(address(poolMock), initTokenAmount * 100);
        weth.deposit{value: initTokenAmount * 100}();
        weth.transfer(address(poolMock), initTokenAmount * 100);
    }

    // --- Math ---
    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10**9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10**27;
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    // --- Default actions/scenarios ---
    function default_create_liquidatable_position(
        uint256 liquidatableCollateralPrice
    ) internal returns (address) {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(
            safeManager,
            safe,
            address(liquidationEngine),
            address(saviour)
        );
        assertEq(
            liquidationEngine.chosenSAFESaviour("eth", safeHandler),
            address(saviour)
        );

        ethMedian.updateCollateralPrice(liquidatableCollateralPrice);
        ethFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("eth");

        return safeHandler;
    }

    function default_save(uint256 safe, address safeHandler) internal {
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(
            safeManager,
            safe,
            address(coinJoin),
            safeEngine.coinBalance(safeHandler)
        );
        alice.doProtectSAFE(
            safeManager,
            safe,
            address(liquidationEngine),
            address(saviour)
        );
        assertEq(
            liquidationEngine.chosenSAFESaviour("eth", safeHandler),
            address(saviour)
        );

        ethMedian.updateCollateralPrice(initETHUSDPrice / 2);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 2);
        oracleRelayer.updateCollateralPrice("eth");

        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            (initTokenAmount * initTokenAmount) / 5
        );
        assertEq(
            lpToken.balanceOf(address(saviour)),
            (initTokenAmount * initTokenAmount) / 5
        );
        assertEq(
            saviour.lpTokenCover("eth", safeHandler),
            (initTokenAmount * initTokenAmount) / 5
        );

        liquidationEngine.modifyParameters(
            "eth",
            "liquidationQuantity",
            rad(100000 ether)
        );
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationPenalty",
            1.1 ether
        );

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(
            address(this)
        );
        uint256 preSaveSecondCurveTokenBalance = secondCurveToken.balanceOf(
            address(saviour)
        );
        uint256 preSaveWETHKeeperBalance = weth.balanceOf(address(this));

        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        uint256 sysCoinReserve = saviour.underlyingReserves(
            safeHandler,
            address(systemCoin)
        );
        uint256 secondCurveTokenReserve = saviour.underlyingReserves(
            safeHandler,
            address(secondCurveToken)
        );
        uint256 wethReserve = saviour.underlyingReserves(
            safeHandler,
            address(weth)
        );

        assertEq(auction, 0);
        assertTrue(
            sysCoinReserve > 0 &&
                secondCurveTokenReserve > 0 &&
                wethReserve == 0
        );
        assertTrue(
            systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance >
                0 ||
                weth.balanceOf(address(this)) - preSaveWETHKeeperBalance > 0
        );
        assertTrue(
            secondCurveToken.balanceOf(address(saviour)) -
                preSaveSecondCurveTokenBalance ==
                secondCurveTokenReserve
        );
        assertEq(saviour.lpTokenCover("eth", safeHandler), 0);
    }

    function default_second_save(uint256 safe, address safeHandler) internal {
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            0,
            int256(defaultTokenAmount * 4)
        );

        ethMedian.updateCollateralPrice(initETHUSDPrice / 6);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 6);
        oracleRelayer.updateCollateralPrice("eth");

        liquidationEngine.modifyParameters(
            "eth",
            "liquidationQuantity",
            rad(111 ether)
        );
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationPenalty",
            1.1 ether
        );

        uint256 oldSysCoinReserve = saviour.underlyingReserves(
            safeHandler,
            address(systemCoin)
        );
        uint256 oldSecondCurveTokenReserve = saviour.underlyingReserves(
            safeHandler,
            address(secondCurveToken)
        );
        uint256 oldWethReserve = saviour.underlyingReserves(
            safeHandler,
            address(weth)
        );
        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);

        uint256 sysCoinReserve = saviour.underlyingReserves(
            safeHandler,
            address(systemCoin)
        );
        uint256 secondCurveTokenReserve = saviour.underlyingReserves(
            safeHandler,
            address(secondCurveToken)
        );
        uint256 wethReserve = saviour.underlyingReserves(
            safeHandler,
            address(weth)
        );

        assertEq(auction, 0);
        assertTrue(
            oldSysCoinReserve > sysCoinReserve &&
                secondCurveTokenReserve == oldSecondCurveTokenReserve &&
                wethReserve == oldWethReserve
        );
        assertTrue(
            secondCurveToken.balanceOf(address(saviour)) -
                oldSecondCurveTokenReserve ==
                0
        );
        assertTrue(weth.balanceOf(address(saviour)) - oldWethReserve == 0);
        assertEq(saviour.lpTokenCover("eth", safeHandler), 0);
    }

    function default_liquidate_safe(address safeHandler) internal {
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationQuantity",
            rad(100000 ether)
        );
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationPenalty",
            1.1 ether
        );

        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        // the full SAFE is liquidated
        (uint256 lockedCollateral, uint256 generatedDebt) = safeEngine.safes(
            "eth",
            me
        );
        assertEq(lockedCollateral, 0);
        assertEq(generatedDebt, 0);
        // all debt goes to the accounting engine
        assertTrue(accountingEngine.totalQueuedDebt() > 0);
        // auction is for all collateral
        (
            ,
            uint256 amountToSell,
            ,
            ,
            ,
            ,
            ,
            uint256 amountToRaise
        ) = collateralAuctionHouse.bids(auction);
        assertEq(amountToSell, defaultCollateralAmount);
        assertEq(amountToRaise, rad(1100 ether));
    }

    function default_create_liquidatable_position_deposit_cover(
        uint256 liquidatableCollateralPrice
    ) internal returns (address) {
        // Create position
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(
            safeManager,
            safe,
            address(liquidationEngine),
            address(saviour)
        );
        assertEq(
            liquidationEngine.chosenSAFESaviour("eth", safeHandler),
            address(saviour)
        );

        // Change oracle price
        ethMedian.updateCollateralPrice(liquidatableCollateralPrice);
        ethFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("eth");

        // Deposit cover
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            defaultLpTokenToDeposit
        );
        assertEq(lpToken.balanceOf(address(saviour)), defaultLpTokenToDeposit);
        assertEq(
            saviour.lpTokenCover("eth", safeHandler),
            defaultLpTokenToDeposit
        );

        return safeHandler;
    }

    function default_create_position_deposit_cover()
        internal
        returns (uint256, address)
    {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        // Deposit cover
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            defaultLpTokenToDeposit
        );
        assertEq(lpToken.balanceOf(address(saviour)), defaultLpTokenToDeposit);
        assertEq(
            saviour.lpTokenCover("eth", safeHandler),
            defaultLpTokenToDeposit
        );

        return (safe, safeHandler);
    }

    function default_modify_collateralization(uint256 safe, address safeHandler)
        internal
    {
        weth.approve(address(collateralJoin), uint256(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            int256(defaultCollateralAmount),
            int256(defaultTokenAmount * 10)
        );
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);
        assertEq(saviour.restrictUsage(), 0);

        assertEq(address(saviour.coinJoin()), address(coinJoin));
        assertEq(address(saviour.collateralJoin()), address(collateralJoin));
        assertEq(
            address(saviour.liquidationEngine()),
            address(liquidationEngine)
        );
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.systemCoin()), address(systemCoin));
        assertEq(address(saviour.safeEngine()), address(safeEngine));
        assertEq(address(saviour.safeManager()), address(safeManager));
        assertEq(address(saviour.saviourRegistry()), address(saviourRegistry));
        assertEq(address(saviour.curvePool()), address(poolMock));
        assertEq(address(saviour.lpToken()), address(lpToken));
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
        alice.doModifyParameters(
            saviour,
            "systemCoinOrcl",
            address(systemCoinOracle)
        );
    }

    function testFail_deposit_liq_engine_not_approved() public {
        liquidationEngine.disconnectSAFESaviour(address(saviour));

        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            1,
            defaultLpTokenToDeposit
        );
    }

    function testFail_deposit_null_lp_token_amount() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doDeposit(saviour, DSToken(address(lpToken)), "eth", 1, 0);
    }

    function testFail_deposit_inexistent_safe() public {
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            1,
            defaultLpTokenToDeposit
        );
    }

    function test_deposit_twice() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();

        // Second deposit
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            defaultLpTokenToDeposit
        );

        // Checks
        assertTrue(
            lpToken.balanceOf(address(saviour)) > 0 &&
                saviour.lpTokenCover("eth", safeHandler) > 0
        );
        assertEq(
            saviour.lpTokenCover("eth", safeHandler),
            defaultLpTokenToDeposit * 2
        );
        assertEq(
            lpToken.balanceOf(address(saviour)),
            defaultLpTokenToDeposit * 2
        );
    }

    function test_deposit_after_everything_withdrawn() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentLPBalanceAlice = lpToken.balanceOf(address(alice));
        uint256 currentLPBalanceSaviour = lpToken.balanceOf(address(saviour));
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler),
            address(alice)
        );

        // Checks
        assertEq(
            lpToken.balanceOf(address(alice)),
            currentLPBalanceAlice + currentLPBalanceSaviour
        );
        assertTrue(
            lpToken.balanceOf(address(saviour)) == 0 &&
                saviour.lpTokenCover("eth", safeHandler) == 0
        );

        // Deposit again
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            currentLPBalanceSaviour
        );

        // Checks
        assertTrue(
            lpToken.balanceOf(address(saviour)) > 0 &&
                saviour.lpTokenCover("eth", safeHandler) > 0
        );
        assertEq(
            saviour.lpTokenCover("eth", safeHandler),
            currentLPBalanceSaviour
        );
        assertEq(lpToken.balanceOf(address(saviour)), currentLPBalanceSaviour);
        assertEq(lpToken.balanceOf(address(alice)), currentLPBalanceAlice);
    }

    function testFail_withdraw_unauthorized() public {
        (uint256 safe, ) = default_create_position_deposit_cover();

        // Withdraw by unauthed
        FakeUser bob = new FakeUser();
        bob.doWithdraw(
            saviour,
            "eth",
            safe,
            lpToken.balanceOf(address(saviour)),
            address(bob)
        );
    }

    function testFail_withdraw_more_than_deposited() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();
        uint256 currentLPBalance = lpToken.balanceOf(address(this));
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler) + 1,
            address(this)
        );
    }

    function testFail_withdraw_null() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();
        alice.doWithdraw(saviour, "eth", safe, 0, address(this));
    }

    function test_withdraw() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentLPBalanceAlice = lpToken.balanceOf(address(alice));
        uint256 currentLPBalanceSaviour = lpToken.balanceOf(address(saviour));
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler),
            address(alice)
        );

        // Checks
        assertEq(
            lpToken.balanceOf(address(alice)),
            currentLPBalanceAlice + currentLPBalanceSaviour
        );
        assertTrue(
            lpToken.balanceOf(address(saviour)) == 0 &&
                saviour.lpTokenCover("eth", safeHandler) == 0
        );
    }

    function test_withdraw_twice() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();

        // Withdraw once
        uint256 currentLPBalanceAlice = lpToken.balanceOf(address(alice));
        uint256 currentLPBalanceSaviour = lpToken.balanceOf(address(saviour));
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler) / 2,
            address(alice)
        );

        // Checks
        assertEq(
            lpToken.balanceOf(address(alice)),
            currentLPBalanceAlice + currentLPBalanceSaviour / 2
        );
        assertTrue(
            lpToken.balanceOf(address(saviour)) ==
                currentLPBalanceSaviour / 2 &&
                saviour.lpTokenCover("eth", safeHandler) ==
                currentLPBalanceSaviour / 2
        );

        // Withdraw again
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler),
            address(alice)
        );

        // Checks
        assertEq(
            lpToken.balanceOf(address(alice)),
            currentLPBalanceAlice + currentLPBalanceSaviour
        );
        assertTrue(
            lpToken.balanceOf(address(saviour)) == 0 &&
                saviour.lpTokenCover("eth", safeHandler) == 0
        );
    }

    function test_withdraw_custom_dst() public {
        (
            uint256 safe,
            address safeHandler
        ) = default_create_position_deposit_cover();

        // Withdraw
        uint256 currentLPBalanceAlice = lpToken.balanceOf(address(alice));
        uint256 currentLPBalanceSaviour = lpToken.balanceOf(address(saviour));
        alice.doWithdraw(
            saviour,
            "eth",
            safe,
            saviour.lpTokenCover("eth", safeHandler),
            address(0xb1)
        );

        // Checks
        assertEq(lpToken.balanceOf(address(0xb1)), currentLPBalanceSaviour);
        assertEq(lpToken.balanceOf(address(alice)), currentLPBalanceAlice);
        assertTrue(
            lpToken.balanceOf(address(saviour)) == 0 &&
                saviour.lpTokenCover("eth", safeHandler) == 0
        );
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
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        uint256 sysCoins = saviour.getTokensForSaving("eth", safeHandler, 0);

        assertEq(sysCoins, 0);
    }

    function test_getTokensForSaving_inexistent_position() public {
        uint256 sysCoins = saviour.getTokensForSaving("eth", address(0x1), 100);

        assertEq(sysCoins, 0);
    }

    function test_getTokensForSaving_no_debt() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        uint256 sysCoins = saviour.getTokensForSaving("eth", safeHandler, 100);

        assertEq(sysCoins, 0);
    }

    function test_getTokensForSaving_coins_higher_than_debt() public {
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        uint256 sysCoins = saviour.getTokensForSaving(
            "eth",
            safeHandler,
            defaultTokenAmount * 20
        );

        assertEq(sysCoins, defaultTokenAmount * 10);
    }

    function test_getTokensForSaving_coins_between_floor_and_debt() public {
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        uint256 sysCoins = saviour.getTokensForSaving(
            "eth",
            safeHandler,
            defaultTokenAmount * 8
        );

        assertEq(sysCoins, defaultTokenAmount * 8);
    }

    function test_getTokensForSaving_coins_below_floor_and_debt() public {
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        uint256 sysCoins = saviour.getTokensForSaving(
            "eth",
            safeHandler,
            ethFloor / 2
        );

        assertEq(sysCoins, 0);
    }

    function testFail_saveSAFE_invalid_caller() public {
        address safeHandler = default_create_liquidatable_position_deposit_cover(
                initETHUSDPrice / 2
            );
        saviour.saveSAFE(address(this), "eth", safeHandler);
    }

    function test_saveSAFE_no_cover() public {
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        default_liquidate_safe(safeHandler);
    }

    function test_saveSAFE_cannot_save_safe() public {
        // Create position
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);

        weth.approve(address(collateralJoin), uint256(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            int256(defaultCollateralAmount),
            int256(defaultTokenAmount * 10)
        );

        alice.doProtectSAFE(
            safeManager,
            safe,
            address(liquidationEngine),
            address(saviour)
        );
        assertEq(
            liquidationEngine.chosenSAFESaviour("eth", safeHandler),
            address(saviour)
        );

        // Change oracle price
        ethMedian.updateCollateralPrice(initETHUSDPrice / 5);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 5);
        oracleRelayer.updateCollateralPrice("eth");

        // Deposit cover and make sure the pool barely sends tokens
        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            defaultLpTokenToDeposit / 20
        );
        poolMock.toggleSendFewTokens();

        default_liquidate_safe(safeHandler);

        assertTrue(
            saviour.underlyingReserves(
                safeHandler,
                address(secondCurveToken)
            ) == 0
        );
        assertEq(
            saviour.underlyingReserves(safeHandler, address(secondCurveToken)),
            secondCurveToken.balanceOf(address(saviour))
        );
        assertTrue(saviour.underlyingReserves(safeHandler, address(weth)) == 0);
        assertEq(
            saviour.underlyingReserves(safeHandler, address(weth)),
            weth.balanceOf(address(saviour))
        );
    }

    function test_saveSAFE_cannot_pay_keeper() public {
        address safeHandler = default_create_liquidatable_position(
            initETHUSDPrice / 2
        );
        saviour.modifyParameters("minKeeperPayoutValue", 1000000000 ether);
        default_liquidate_safe(safeHandler);
    }

    function test_saveSAFE() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);
    }

    function test_saveSAFE_accumulate_rate() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);

        // Warp and save
        hevm.warp(now + 2 days);
        taxCollector.taxSingle("eth");

        weth.approve(address(collateralJoin), uint256(-1));
        collateralJoin.join(address(safeHandler), defaultCollateralAmount);
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            int256(defaultCollateralAmount),
            int256(defaultTokenAmount * 10)
        );

        alice.doTransferInternalCoins(
            safeManager,
            safe,
            address(coinJoin),
            safeEngine.coinBalance(safeHandler)
        );
        alice.doProtectSAFE(
            safeManager,
            safe,
            address(liquidationEngine),
            address(saviour)
        );

        assertEq(
            liquidationEngine.chosenSAFESaviour("eth", safeHandler),
            address(saviour)
        );

        ethMedian.updateCollateralPrice(initETHUSDPrice / 2);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 2);
        oracleRelayer.updateCollateralPrice("eth");

        alice.doDeposit(
            saviour,
            DSToken(address(lpToken)),
            "eth",
            safe,
            defaultLpTokenToDeposit * 100
        );
        assertEq(
            lpToken.balanceOf(address(saviour)),
            defaultLpTokenToDeposit * 100
        );

        liquidationEngine.modifyParameters(
            "eth",
            "liquidationQuantity",
            rad(100000 ether)
        );
        liquidationEngine.modifyParameters(
            "eth",
            "liquidationPenalty",
            1.1 ether
        );

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(
            address(this)
        );
        uint256 preSaveSecondTokenSaviourBalance = secondCurveToken.balanceOf(
            address(saviour)
        );
        uint256 preSaveWETHKeeperBalance = weth.balanceOf(address(this));

        uint256 auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        uint256 sysCoinReserve = saviour.underlyingReserves(
            safeHandler,
            address(systemCoin)
        );
        uint256 secondTokenReserve = saviour.underlyingReserves(
            safeHandler,
            address(secondCurveToken)
        );

        assertEq(auction, 0);
        assertTrue(sysCoinReserve > 0 || secondTokenReserve > 0);
        assertTrue(
            systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance >
                0 ||
                secondCurveToken.balanceOf(address(saviour)) -
                    preSaveSecondTokenSaviourBalance >
                0 ||
                weth.balanceOf(address(this)) - preSaveWETHKeeperBalance > 0
        );
        assertEq(lpToken.balanceOf(address(saviour)), 0);
        assertEq(saviour.lpTokenCover("eth", safeHandler), 0);

        (uint256 lockedCollateral, uint256 generatedDebt) = safeEngine.safes(
            "eth",
            safeHandler
        );
        (, uint256 accumulatedRate, , , , ) = safeEngine.collateralTypes("eth");
        assertTrue(
            (lockedCollateral * ray(ethFSM.read()) * 100) /
                ((generatedDebt *
                    oracleRelayer.redemptionPrice() *
                    accumulatedRate) / 10**27) >=
                minCRatio / 10**17
        );
    }

    function testFail_saveSAFE_withdraw_cover() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        alice.doWithdraw(saviour, "eth", safe, 1, address(this));
    }

    function test_saveSAFE_get_each_reserve() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        uint256 oldSysCoinBalance = systemCoin.balanceOf(address(alice));
        uint256 oldCurveTokenBalance = secondCurveToken.balanceOf(
            address(alice)
        );

        uint256 sysCoinReserve = saviour.underlyingReserves(
            safeHandler,
            address(systemCoin)
        );
        uint256 secondCurveTokenBalance = saviour.underlyingReserves(
            safeHandler,
            address(secondCurveToken)
        );
        uint256 wethReserve = saviour.underlyingReserves(
            safeHandler,
            address(weth)
        );
        assertTrue(wethReserve == 0);

        alice.doGetReserves(saviour, safe, address(systemCoin), address(alice));
        alice.doGetReserves(
            saviour,
            safe,
            address(secondCurveToken),
            address(alice)
        );

        assertTrue(
            systemCoin.balanceOf(address(alice)) - sysCoinReserve ==
                oldSysCoinBalance
        );
        assertTrue(
            secondCurveToken.balanceOf(address(alice)) -
                secondCurveTokenBalance ==
                oldCurveTokenBalance
        );

        assertEq(systemCoin.balanceOf(address(saviour)), 0);
        assertEq(secondCurveToken.balanceOf(address(saviour)), 0);
        assertEq(weth.balanceOf(address(saviour)), 0);
    }

    function testFail_save_twice_without_waiting() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);
        default_second_save(safe, safeHandler);
    }

    function testFail_getReserves_invalid_caller() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_save(safe, safeHandler);

        saviour.getReserves(safe, address(systemCoin), address(alice));
    }
}
