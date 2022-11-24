pragma solidity 0.6.7;
pragma experimental ABIEncoderV2;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "../interfaces/IERC721.sol";

// GEB
import { SAFEEngine } from "geb/SAFEEngine.sol";
import { Coin } from "geb/Coin.sol";
import { LiquidationEngine } from "geb/LiquidationEngine.sol";
import { AccountingEngine } from "geb/AccountingEngine.sol";
import { TaxCollector } from "geb/TaxCollector.sol";
import { BasicCollateralJoin, CoinJoin } from "geb/BasicTokenAdapters.sol";
import { OracleRelayer } from "geb/OracleRelayer.sol";
import { EnglishCollateralAuctionHouse } from "geb/CollateralAuctionHouse.sol";
import { GebSafeManager } from "geb-safe-manager/GebSafeManager.sol";

// Uniswap
import "../integrations/uniswap/uni-v3/core/UniswapV3Factory.sol";
import "../integrations/uniswap/uni-v3/core/UniswapV3Pool.sol";
import { TickMath } from "../integrations/uniswap/uni-v3/core/libraries/TickMath.sol";
import { NonfungiblePositionManager } from "../integrations/uniswap/uni-v3/periphery/NonFungiblePositionManager.sol";
import { INonfungiblePositionManager } from "../integrations/uniswap/uni-v3/periphery/interfaces/INonfungiblePositionManager.sol";
import { SwapRouter } from "../integrations/uniswap/uni-v3/periphery/SwapRouter.sol";
import { ISwapRouter } from "../integrations/uniswap/uni-v3/periphery/interfaces/ISwapRouter.sol";

// Saviour
import "../saviours/NativeUnderlyingMaxUniswapV3SafeSaviour.sol";
import { SAFESaviourRegistry } from "../SAFESaviourRegistry.sol";

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

contract FakeUser {
    function doModifyParameters(
        NativeUnderlyingMaxUniswapV3SafeSaviour saviour,
        bytes32 parameter,
        uint256 data
    ) public {
        saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
        NativeUnderlyingMaxUniswapV3SafeSaviour saviour,
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

    function doApproveSAFEModification(SAFEEngine safeEngine, address usr) public {
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
        NativeUnderlyingMaxUniswapV3SafeSaviour saviour,
        NonfungiblePositionManager positionManager,
        uint256 safeId,
        uint256 tokenId
    ) public {
        positionManager.approve(address(saviour), tokenId);
        saviour.deposit(safeId, tokenId);
    }

    function doWithdraw(
        NativeUnderlyingMaxUniswapV3SafeSaviour saviour,
        NonfungiblePositionManager positionManager,
        uint256 safeId,
        uint256 tokenId,
        address dst
    ) public {
        saviour.withdraw(safeId, tokenId, dst);
    }

    function doGetReserves(
        NativeUnderlyingMaxUniswapV3SafeSaviour saviour,
        uint256 safeId,
        address dst
    ) public {
        saviour.getReserves(safeId, dst);
    }

    function doTransferInternalCoins(
        GebSafeManager manager,
        uint256 safe,
        address dst,
        uint256 amt
    ) public {
        manager.transferInternalCoins(safe, dst, amt);
    }
}

abstract contract Hevm {
    function warp(uint256) public virtual;

    function roll(uint256) public virtual;
}

contract NativeUnderlyingMaxUniswapV3SafeSaviourTest is DSTest {
    Hevm hevm;

    // Uniswap
    UniswapV3Factory uniV3Factory;
    NonfungiblePositionManager positionManager;
    SwapRouter swapRouter;
    UniswapV3Pool pool;

    // GEB core
    Coin systemCoin;
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

    // Savior
    NativeUnderlyingMaxUniswapV3SafeSaviour saviour;
    SAFESaviourRegistry saviourRegistry;

    // Misc
    WETH9_ weth;
    FakeUser alice;

    uint256 initTokenAmount = 100000 ether;

    uint256 initETHUSDPrice = 4000 ether;
    uint256 initRAIUSDPrice = 3 ether;

    // Assume ETH at 4k, RAI at 3
    uint256 initETHRAIPairLiquidity = 6 ether;
    uint256 initRAIETHPairLiquidity = 8000 ether;

    // Saviour params
    bool isSystemCoinToken0;
    uint256 saveCooldown = 1 days;
    uint256 minKeeperPayoutValue = 1000 ether;

    // Core system params
    uint256 minCRatio = 1.5 ether;
    uint256 ethToMint = 5000 ether;
    uint256 ethCeiling = uint256(-1);
    uint256 ethFloor = 10 ether;
    uint256 ethLiquidationPenalty = 1 ether;

    // Test safe config
    uint256 defaultCollateralAmount = 18 ether;
    uint256 defaultTokenAmount = 8000 ether; // max 16k RAI

    // Uniswap
    uint24 poolFee = uint24(3000);

    // constants
    uint256 WAD = 10**18;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

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
        oracleRelayer.modifyParameters("eth", "liquidationCRatio", ray(minCRatio));

        safeEngine.addAuthorization(address(oracleRelayer));
        oracleRelayer.updateCollateralPrice("eth");

        accountingEngine = new AccountingEngine(address(safeEngine), address(0x1), address(0x2));
        safeEngine.addAuthorization(address(accountingEngine));

        taxCollector = new TaxCollector(address(safeEngine));
        taxCollector.initializeCollateralType("eth");
        taxCollector.modifyParameters("primaryTaxReceiver", address(accountingEngine));
        taxCollector.modifyParameters("eth", "stabilityFee", 1000000564701133626865910626); // 5% / day
        safeEngine.addAuthorization(address(taxCollector));

        liquidationEngine = new LiquidationEngine(address(safeEngine));
        liquidationEngine.modifyParameters("accountingEngine", address(accountingEngine));
        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(100000 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        safeEngine.addAuthorization(address(liquidationEngine));
        accountingEngine.addAuthorization(address(liquidationEngine));

        weth = new WETH9_();
        weth.deposit{ value: initTokenAmount }();

        collateralJoin = new BasicCollateralJoin(address(safeEngine), "eth", address(weth));

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
        liquidationEngine.modifyParameters("eth", "collateralAuctionHouse", address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", ethLiquidationPenalty);

        safeEngine.addAuthorization(address(collateralAuctionHouse));
        safeEngine.approveSAFEModification(address(collateralAuctionHouse));

        safeManager = new GebSafeManager(address(safeEngine));
        oracleRelayer.updateCollateralPrice("eth");

        // Uniswap setup
        isSystemCoinToken0 = address(systemCoin) < address(weth);
        uniV3Factory = new UniswapV3Factory();
        positionManager = new NonfungiblePositionManager(address(uniV3Factory), address(weth), address(0));
        swapRouter = new SwapRouter(address(uniV3Factory), address(weth));
        pool = UniswapV3Pool(
            positionManager.createAndInitializePoolIfNecessary(
                address(systemCoin),
                address(weth),
                poolFee,
                // sqrtx96 calculated using: https://uniswap-v3-calculator.netlify.app/
                isSystemCoinToken0
                    ? uint160(2169752589937389744715760893)
                    : uint160(2893003453249852992954347857494)
            )
        );

        // codeHash of the pool contract to use the PoolAddress library
        // Needs to be manually updated if the pool contract is changed
        log_bytes32(keccak256(type(UniswapV3Pool).creationCode));

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);
        saviour = new NativeUnderlyingMaxUniswapV3SafeSaviour(
            isSystemCoinToken0,
            address(coinJoin),
            address(collateralJoin),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(positionManager),
            address(pool),
            address(liquidationEngine),
            address(taxCollector),
            address(safeEngine),
            address(systemCoinOracle),
            minKeeperPayoutValue
        );

        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        alice = new FakeUser();
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

    // --- Helpers ---

    function helper_set_collateral_price(uint256 newPrice) internal {
        ethMedian.updateCollateralPrice(newPrice);
        ethFSM.updateCollateralPrice(newPrice);
        oracleRelayer.updateCollateralPrice("eth");
    }

    // --- Default actions ---
    function default_modify_collateralization(uint256 safe, address safeHandler) internal {
        weth.approve(address(collateralJoin), uint256(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            int256(defaultCollateralAmount),
            int256(defaultTokenAmount)
        );
    }

    function default_open_safe_and_modify_collateralization() internal returns (uint256, address) {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        return (safe, safeHandler);
    }

    function default_mint_full_range_uni_position(uint256 amount0, uint256 amount1)
        internal
        returns (uint256)
    {
        return
            default_mint_uni_position(
                isSystemCoinToken0 ? address(systemCoin) : address(weth),
                isSystemCoinToken0 ? address(weth) : address(systemCoin),
                amount0,
                amount1,
                -887220,
                887220
            );
    }

    function default_mint_one_sided_uni_position(
        address token0,
        address token1,
        bool isToken0Side,
        uint256 amount
    ) internal returns (uint256) {
        (, int24 tick, , , , , ) = pool.slot0();
        int24 tickSpacing = pool.tickSpacing();
        int24 flooredTick = tick - (tick % tickSpacing);
        return
            default_mint_uni_position(
                token0,
                token1,
                isToken0Side ? amount : 0,
                isToken0Side ? 0 : amount,
                isToken0Side ? flooredTick + 2 * tickSpacing : -887220,
                isToken0Side ? int24(887220) : flooredTick - tickSpacing
            );
    }

    function default_mint_uni_position(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint256) {
        DSToken(token0).approve(address(positionManager), uint256(-1));
        DSToken(token1).approve(address(positionManager), uint256(-1));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: poolFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, , , ) = positionManager.mint(params);

        return tokenId;
    }

    function default_create_position_and_deposit(uint256 safe) internal returns (uint256) {
        uint256 tokenId = default_mint_full_range_uni_position(
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        default_deposit_position(safe, tokenId);

        return tokenId;
    }

    function default_deposit_position(uint256 safe, uint256 tokenId) internal {
        address safeHandler = safeManager.safes(safe);

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, safe, tokenId);

        uint256 id = saviour.lpTokenCover(safeHandler);

        assertEq(id, tokenId);

        // Connect savior
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        assertEq(positionManager.ownerOf(tokenId), address(saviour));
    }

    function default_withdraw_position(uint256 safe, uint256 tokenId) internal {
        address safeHandler = safeManager.safes(safe);
        uint256 oldId = saviour.lpTokenCover(safeHandler);
        assertEq(oldId, tokenId);

        alice.doWithdraw(saviour, positionManager, safe, tokenId, address(alice));

        uint256 newId = saviour.lpTokenCover(safeHandler);

        assertEq(newId, 0);

        assertEq(positionManager.ownerOf(tokenId), address(alice));
    }

    function default_create_liquidatable_position() internal returns (uint256, address) {
        (uint256 safe, address safeHandler) = default_open_safe_and_modify_collateralization();

        // Tank collateral price
        helper_set_collateral_price(initETHUSDPrice / 3);

        return (safe, safeHandler);
    }

    function default_create_liquidatable_position_deposit_cover()
        internal
        returns (
            uint256,
            address,
            uint256
        )
    {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();
        uint256 tokenId = default_create_position_and_deposit(safe);

        return (safe, safeHandler, tokenId);
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertTrue(saviour.isSystemCoinToken0() == isSystemCoinToken0);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);
        assertEq(saviour.restrictUsage(), 0);

        assertEq(address(saviour.positionManager()), address(positionManager));
        assertEq(address(saviour.systemCoin()), address(systemCoin));
        assertEq(address(saviour.coinJoin()), address(coinJoin));
        assertEq(address(saviour.collateralJoin()), address(collateralJoin));
        assertEq(address(saviour.collateralToken()), address(weth));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.taxCollector()), address(taxCollector));
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.safeManager()), address(safeManager));
        assertEq(address(saviour.safeEngine()), address(safeEngine));
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
        saviour.modifyParameters("liquidationEngine", address(liquidationEngine));
        saviour.modifyParameters("taxCollector", address(taxCollector));

        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.taxCollector()), address(taxCollector));
    }

    function testFail_modify_address_unauthed() public {
        alice.doModifyParameters(saviour, "systemCoinOrcl", address(systemCoinOracle));
    }

    function testFail_deposit_liq_engine_not_approved() public {
        liquidationEngine.disconnectSAFESaviour(address(saviour));

        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId = default_mint_full_range_uni_position(
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, safe, tokenId);
    }

    function testFail_deposit_inexistent_safe() public {
        uint256 tokenId = default_mint_full_range_uni_position(
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, uint256(-1), tokenId);
    }

    function test_deposit_and_withdraw_one_position() public {
        (uint256 safe, ) = default_open_safe_and_modify_collateralization();
        uint256 tokenId = default_create_position_and_deposit(safe);
        default_withdraw_position(safe, tokenId);
    }

    function testFail_already_withdrawn() public {
        (uint256 safe, ) = default_open_safe_and_modify_collateralization();
        uint256 tokenId = default_create_position_and_deposit(safe);

        default_withdraw_position(safe, tokenId);
        default_withdraw_position(safe, tokenId);
    }

    function testFail_deposit_third_position() public {
        (uint256 safe, ) = default_open_safe_and_modify_collateralization();
        default_create_position_and_deposit(safe);
        default_create_position_and_deposit(safe);
        default_create_position_and_deposit(safe);
    }

    function test_getCollateralPrice_zero_price() public {
        ethFSM.updateCollateralPrice(0);
        assertEq(saviour.getCollateralPrice(), 0);
    }

    function test_getCollateralPrice_invalid() public {
        ethFSM.changeValidity();
        assertEq(saviour.getCollateralPrice(), 0);
    }

    function test_getCollateralPrice_null_fsm() public {
        oracleRelayer.modifyParameters("eth", "orcl", address(0));
        assertEq(saviour.getCollateralPrice(), 0);
    }

    function test_getCollateralPrice() public {
        assertEq(saviour.getCollateralPrice(), initETHUSDPrice);
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

    function test_getTokensForSaving_inexistant_safe() public {
        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(
            address(0x1),
            uint256(-1),
            uint256(-1)
        );

        assertEq(collateral, 0);
        assertEq(sysCoins, 0);
    }

    function test_getTokensForSaving_null_collateral_price() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        // Collateral price to 0 means it can't be saved unless all of the debt is repaid
        helper_set_collateral_price(0);

        (, , , , , uint256 liquidationPrice) = safeEngine.collateralTypes("eth");
        assertEq(liquidationPrice, 0);

        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(
            safeHandler,
            0,
            initETHRAIPairLiquidity * 100
        );

        assertEq(sysCoins, 0);
        assertEq(sysCoins, 0);
    }

    function test_getTokensForSaving_save_only_with_sys_coins() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();
        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(
            safeHandler,
            initRAIETHPairLiquidity * 100,
            0
        );

        assertGt(sysCoins, 0);
        assertEq(collateral, 0);
    }

    function test_getTokensForSaving_save_only_with_collateral() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();
        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(
            safeHandler,
            0,
            initETHRAIPairLiquidity * 100
        );

        assertEq(sysCoins, 0);
        assertGt(collateral, 0);
    }

    function test_getTokensForSaving_both_tokens_used() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();
        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(
            safeHandler,
            initRAIETHPairLiquidity * 100,
            initETHRAIPairLiquidity * 100
        );

        assertGt(sysCoins, 0);
        assertGt(collateral, 0);
    }

    function test_getTokensForSaving_not_enough_lp_collateral() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        (uint256 sysCoins, uint256 collateral) = saviour.getTokensForSaving(safeHandler, 1, 1);

        assertEq(sysCoins, 0);
        assertEq(sysCoins, 0);
    }

    function test_getKeeperPayoutTokens_null_collateral_price() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();
        helper_set_collateral_price(0);

        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(
            safeHandler,
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        assertEq(sysCoins, 0);
        assertEq(collateral, 0);
    }

    function test_getKeeperPayoutTokens_null_sys_coin_price() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();
        systemCoinOracle.updateCollateralPrice(0);
        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(
            safeHandler,
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        assertEq(sysCoins, 0);
        assertEq(collateral, 0);
    }

    function test_getKeeperPayoutTokens_only_sys_coins_used() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(
            safeHandler,
            initRAIETHPairLiquidity * 100,
            0
        );

        assertEq(sysCoins, (minKeeperPayoutValue * WAD) / systemCoinOracle.read());
        assertEq(collateral, 0);
    }

    function test_getKeeperPayoutTokens_only_collateral_used() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(
            safeHandler,
            0,
            initETHRAIPairLiquidity * 100
        );

        assertEq(sysCoins, 0);
        assertEq(collateral, (minKeeperPayoutValue * WAD) / ethFSM.read());
    }

    function test_getKeeperPayoutTokens_both_tokens_used() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(
            safeHandler,
            (minKeeperPayoutValue * WAD) / 2 / systemCoinOracle.read(), // Only half of the keeperpayout available
            initETHRAIPairLiquidity * 100
        );

        // Half syscoin, half collateral
        assertEq(sysCoins, (minKeeperPayoutValue * WAD) / systemCoinOracle.read() / 2);
        assertEq(collateral, (minKeeperPayoutValue * WAD) / ethFSM.read() / 2);
    }

    function test_getKeeperPayoutTokens_not_enough_tokens_to_pay() public {
        (, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        (uint256 sysCoins, uint256 collateral) = saviour.getKeeperPayoutTokens(safeHandler, 1, 1);

        assertEq(sysCoins, 0);
        assertEq(collateral, 0);
    }

    function test_saveSAFE_savior_not_connected() public {
        (uint256 safe, address safeHandler, ) = default_create_liquidatable_position_deposit_cover();

        // Disconnect savior
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(0));

        liquidationEngine.liquidateSAFE("eth", safeHandler);

        (uint256 debtAfter, uint256 collateralAfter) = safeEngine.safes("eth", safeHandler);

        // Liquidation went throught
        assertEq(debtAfter, 0);
        assertEq(collateralAfter, 0);
    }

    function test_saveSAFE_position() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();
        uint256 tokenId = default_create_position_and_deposit(safe);

        (uint256 collateralBefore, uint256 debtBefore) = safeEngine.safes("eth", safeHandler);
        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        // Check safe
        assertLt(debtAfter, debtBefore);
        assertGt(collateralAfter, collateralBefore);
        assertGt(debtAfter, 0);
        assertGt(collateralAfter, 0);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 0);
    }

    function test_saveSAFE_single_side_side_systemCoin() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();

        uint256 tokenId = default_mint_one_sided_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            isSystemCoinToken0 ? true : false,
            initRAIETHPairLiquidity
        );

        default_deposit_position(safe, tokenId);

        (uint256 collateralBefore, uint256 debtBefore) = safeEngine.safes("eth", safeHandler);
        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        assertLt(debtAfter, debtBefore);
        assertEq(collateralAfter, collateralBefore);
        assertGt(debtAfter, 0);
        assertGt(collateralAfter, 0);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 0);
    }

    function test_saveSAFE_single_side_side_collateral() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();

        uint256 tokenId = default_mint_one_sided_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            isSystemCoinToken0 ? false : true,
            initETHRAIPairLiquidity * 2
        );

        default_deposit_position(safe, tokenId);

        (uint256 collateralBefore, uint256 debtBefore) = safeEngine.safes("eth", safeHandler);
        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        assertEq(debtAfter, debtBefore);
        assertGt(collateralAfter, collateralBefore);
        assertGt(debtAfter, 0);
        assertGt(collateralAfter, 0);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 0);
    }

    function test_saveSAFE_failure_position() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();

        uint256 tokenId = default_mint_full_range_uni_position(
            initRAIETHPairLiquidity / 4,
            initETHRAIPairLiquidity / 4
        );

        default_deposit_position(safe, tokenId);

        (, , , , , , , uint128 liquidityBefore, , , , ) = positionManager.positions(tokenId);

        (uint256 collateral, uint256 debt) = safeEngine.safes("eth", safeHandler);
        assertGt(debt, 0);
        assertGt(collateral, 0);

        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (collateral, debt) = safeEngine.safes("eth", safeHandler);

        // Safe rekt
        assertEq(debt, 0);
        assertEq(collateral, 0);

        // NFT good
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, tokenId);
        (, , , , , , , uint128 liquidityAfter, , , , ) = positionManager.positions(tokenId);
        assertTrue(liquidityBefore == liquidityAfter);
        assertEq(positionManager.ownerOf(tokenId), address(saviour));

        // Can withdraw the nft
        default_withdraw_position(safe, tokenId);

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 0);
    }

    function test_saveSAFE_accumulated_rate() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();

        hevm.warp(now + 2 days);
        taxCollector.taxSingle("eth");

        uint256 tokenId = default_create_position_and_deposit(safe);

        hevm.warp(now + 2 days);
        taxCollector.taxSingle("eth");

        (uint256 collateralBefore, uint256 debtBefore) = safeEngine.safes("eth", safeHandler);
        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        // Check safe
        assertLt(debtAfter, debtBefore);
        assertGt(collateralAfter, collateralBefore);
        assertGt(debtAfter, 0);
        assertGt(collateralAfter, 0);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 1); // 1 wei rounding error from uniswap
    }

    function test_saveSAFE_repay_in_debt_floor() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();

        // System coin only position
        uint256 tokenId = default_mint_one_sided_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            isSystemCoinToken0 ? true : false,
            defaultTokenAmount + minKeeperPayoutValue / 3 - ethFloor / 2 // In the middle of debtFloor
        );

        default_deposit_position(safe, tokenId);

        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        assertEq(debtAfter, ethFloor);
        assertGt(collateralAfter, 0);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertGt(saviour.underlyingReserves(safeHandler), 0);
        uint256 sysCoinBefore = systemCoin.balanceOf(address(alice));
        alice.doGetReserves(saviour, safe, address(alice));
        assertEq(systemCoin.balanceOf(address(alice)), sysCoinBefore + ethFloor / 2 - 21); // 21 is rounding error from Uniswap
    }

    function test_saveSAFE_after_swaps() public {
        (uint256 safe, address safeHandler) = default_create_liquidatable_position();
        uint256 tokenId = default_create_position_and_deposit(safe);

        default_mint_full_range_uni_position(initRAIETHPairLiquidity, initETHRAIPairLiquidity);

        weth.approve(address(swapRouter), uint256(-1));
        (, int24 tickBefore, , , , , ) = pool.slot0();
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(systemCoin),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: initRAIETHPairLiquidity,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        (, int24 tickAfter, , , , , ) = pool.slot0();

        assertGt(tickAfter, tickBefore);

        uint256 balWethBefore = weth.balanceOf(address(this));
        uint256 balSysCoinBefore = systemCoin.balanceOf(address(this));

        (uint256 collateralBefore, uint256 debtBefore) = safeEngine.safes("eth", safeHandler);
        liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 collateralAfter, uint256 debtAfter) = safeEngine.safes("eth", safeHandler);

        // Check safe
        assertEq(debtAfter, debtBefore); // Debt unchanged because it was use to pay keeper
        assertGt(collateralAfter, collateralBefore);
        assertGt(debtAfter, 0);
        assertGt(collateralAfter, 0);

        // Keeper payout
        assertGt(weth.balanceOf(address(this)), balWethBefore);
        assertGt(systemCoin.balanceOf(address(this)), balSysCoinBefore);

        // Check NFT
        uint256 id = saviour.lpTokenCover(safeHandler);
        assertEq(id, 0);
        try positionManager.ownerOf(tokenId) {
            fail();
        } catch Error(string memory reason) {
            assertEq(reason, "ERC721: owner query for nonexistent token");
        }

        // Check reserves
        assertEq(saviour.underlyingReserves(safeHandler), 0);
    }
}
