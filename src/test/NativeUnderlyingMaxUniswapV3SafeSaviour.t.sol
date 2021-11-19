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
import { UniswapV3LiquidityRemover } from "../integrations/uniswap/uni-v3/UniswapV3LiquidityRemover.sol";

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
    UniswapV3LiquidityRemover uniswapLiquidityRemover;
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
    uint256 initETHUSDPrice = 250 * 10**18;
    uint256 initRAIUSDPrice = 4.242 * 10**18;

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
    uint256 defaultLiquidityMultiplier = 50;
    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;

    address me;

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
        uniswapLiquidityRemover = new UniswapV3LiquidityRemover(address(positionManager));
        pool = UniswapV3Pool(
            positionManager.createAndInitializePoolIfNecessary(
                address(systemCoin),
                address(weth),
                uint24(3000),
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
            address(uniswapLiquidityRemover),
            address(liquidationEngine),
            address(taxCollector),
            address(safeEngine),
            address(systemCoinOracle),
            minKeeperPayoutValue
        );

        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        me = address(this);
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

    // --- Default actions ---
    function default_modify_collateralization(uint256 safe, address safeHandler) internal {
        weth.approve(address(collateralJoin), uint256(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(
            safeManager,
            safe,
            int256(defaultCollateralAmount),
            int256(defaultTokenAmount * 10)
        );
    }

    function default_mint_full_range_uni_position(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256) {
        return default_mint_uni_position(token0, token1, amount0, amount1, -887220, 887220);
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
            fee: uint24(3000),
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

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertTrue(saviour.isSystemCoinToken0() == isSystemCoinToken0);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);
        assertEq(saviour.restrictUsage(), 0);

        assertEq(address(saviour.positionManager()), address(positionManager));
        assertEq(address(saviour.liquidityRemover()), address(uniswapLiquidityRemover));
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
        saviour.modifyParameters("liquidityRemover", address(uniswapLiquidityRemover));

        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.taxCollector()), address(taxCollector));
        assertEq(address(saviour.liquidityRemover()), address(uniswapLiquidityRemover));
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
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, safe, tokenId);
    }

    function testFail_deposit_inexistent_safe() public {
        uint256 tokenId = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, uint256(-1), tokenId);
    }

    function test_deposit_and_withdraw_one_position() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId);
        alice.doDeposit(saviour, positionManager, safe, tokenId);

        (uint256 first, uint256 second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, tokenId);
        assertEq(second, 0);
        assertEq(positionManager.ownerOf(tokenId), address(saviour));

        alice.doWithdraw(saviour, positionManager, safe, tokenId, address(alice));

        (first, second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, 0);
        assertEq(second, 0);
        assertEq(positionManager.ownerOf(tokenId), address(alice));
    }

    function test_deposit_and_withdraw_two_position() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId1 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        uint256 tokenId2 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId1);
        positionManager.transferFrom(address(this), address(alice), tokenId2);

        alice.doDeposit(saviour, positionManager, safe, tokenId1);
        alice.doDeposit(saviour, positionManager, safe, tokenId2);

        (uint256 first, uint256 second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, tokenId1);
        assertEq(second, tokenId2);

        assertEq(positionManager.ownerOf(tokenId1), address(saviour));
        assertEq(positionManager.ownerOf(tokenId2), address(saviour));

        alice.doWithdraw(saviour, positionManager, safe, tokenId1, address(alice));

        (first, second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, tokenId2);
        assertEq(second, 0);

        alice.doWithdraw(saviour, positionManager, safe, tokenId2, address(alice));

        (first, second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, 0);
        assertEq(second, 0);

        assertEq(positionManager.ownerOf(tokenId1), address(alice));
        assertEq(positionManager.ownerOf(tokenId2), address(alice));
    }

    function test_deposit_and_withdraw_reverse_order_two_position() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId1 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        uint256 tokenId2 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId1);
        positionManager.transferFrom(address(this), address(alice), tokenId2);

        alice.doDeposit(saviour, positionManager, safe, tokenId1);
        alice.doDeposit(saviour, positionManager, safe, tokenId2);

        alice.doWithdraw(saviour, positionManager, safe, tokenId2, address(alice));

        (uint256 first, uint256 second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, tokenId1);
        assertEq(second, 0);

        alice.doWithdraw(saviour, positionManager, safe, tokenId1, address(alice));

        (first, second) = saviour.lpTokenCover(safeHandler);
        assertEq(first, 0);
        assertEq(second, 0);

        assertEq(positionManager.ownerOf(tokenId1), address(alice));
        assertEq(positionManager.ownerOf(tokenId2), address(alice));
    }

    function testFail_already_withdrawn() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );
        positionManager.transferFrom(address(this), address(alice), tokenId);

        alice.doDeposit(saviour, positionManager, safe, tokenId);
        alice.doWithdraw(saviour, positionManager, safe, tokenId, address(alice));
        alice.doWithdraw(saviour, positionManager, safe, tokenId, address(alice));
    }

    function testFail_deposit_third_position() public {
        uint256 safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        uint256 tokenId1 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        uint256 tokenId2 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        uint256 tokenId3 = default_mint_full_range_uni_position(
            isSystemCoinToken0 ? address(systemCoin) : address(weth),
            isSystemCoinToken0 ? address(weth) : address(systemCoin),
            initRAIETHPairLiquidity,
            initETHRAIPairLiquidity
        );

        positionManager.transferFrom(address(this), address(alice), tokenId1);
        positionManager.transferFrom(address(this), address(alice), tokenId2);
        positionManager.transferFrom(address(this), address(alice), tokenId3);

        alice.doDeposit(saviour, positionManager, safe, tokenId1);
        alice.doDeposit(saviour, positionManager, safe, tokenId2);
        alice.doDeposit(saviour, positionManager, safe, tokenId3);
    }
}
