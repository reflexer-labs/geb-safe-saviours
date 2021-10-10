pragma solidity >=0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "../integrations/uniswap/uni-v2/UniswapV2Factory.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Pair.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Router02.sol";

import "../integrations/uniswap/liquidity-managers/UniswapV2LiquidityManager.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract UniswapV2LiquidityManagerTest is DSTest {
    Hevm hevm;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;
    UniswapV2LiquidityManager liquidityManager;

    UniswapV2Pair raiWETHPair;

    DSToken systemCoin;
    WETH9_ weth;

    // Params
    bool isSystemCoinToken0;
    uint256 initTokenAmount  = 100000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initRAIUSDPrice  = 4.242 * 10 ** 18;

    uint256 initETHRAIPairLiquidity = 5 ether;               // 1250 USD
    uint256 initRAIETHPairLiquidity = 294.672324375E18;      // 1 RAI = 4.242 USD

    uint256 ethRAISimulationExtraRAI = 100 ether;
    uint256 ethRAISimulationExtraETH = 0.5 ether;

    uint256 initialLPTokens;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        // Tokens
        systemCoin = new DSToken("RAI", "RAI");
        systemCoin.mint(address(this), initTokenAmount);

        weth = new WETH9_();
        weth.deposit{value: initTokenAmount}();

        // Uniswap setup
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPair();
        uniswapRouter = new UniswapV2Router02(address(uniswapFactory), address(weth));
        addPairLiquidityRouter(address(systemCoin), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);
        initialLPTokens = raiWETHPair.balanceOf(address(this));

        // Liquidity manager
        liquidityManager = new UniswapV2LiquidityManager(address(raiWETHPair), address(uniswapRouter));
    }

    // --- Uniswap utils ---
    function createUniswapPair() internal {
        // Setup WETH/RAI pair
        uniswapFactory.createPair(address(weth), address(systemCoin));
        raiWETHPair = UniswapV2Pair(uniswapFactory.getPair(address(weth), address(systemCoin)));

        if (address(raiWETHPair.token0()) == address(systemCoin)) isSystemCoinToken0 = true;
    }
    function addPairLiquidityRouter(address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).approve(address(uniswapRouter), uint(-1));
        DSToken(token2).approve(address(uniswapRouter), uint(-1));
        uniswapRouter.addLiquidity(token1, token2, amount1, amount2, amount1, amount2, address(this), now);
        UniswapV2Pair updatedPair = UniswapV2Pair(uniswapFactory.getPair(token1, token2));
        updatedPair.sync();
    }
    function addPairLiquidityRouterNoSync(address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).approve(address(uniswapRouter), uint(-1));
        DSToken(token2).approve(address(uniswapRouter), uint(-1));
        uniswapRouter.addLiquidity(token1, token2, amount1, amount2, amount1, amount2, address(this), now);
        UniswapV2Pair updatedPair = UniswapV2Pair(uniswapFactory.getPair(token1, token2));
    }
    function addPairLiquidityTransfer(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
        pair.sync();
    }
    function addPairLiquidityTransferNoSync(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
    }

    // --- Tests ---
    function test_getToken0FromLiquidity_zero() public {
        assertEq(liquidityManager.getToken0FromLiquidity(0), 0);
    }
    function test_getToken0FromLiquidity() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initRAIETHPairLiquidity : initETHRAIPairLiquidity;
        assertTrue(liquidityManager.getToken0FromLiquidity(initialLPTokens) >= tokenAmount - 10 ** 10);
        assertTrue(liquidityManager.getToken0FromLiquidity(initialLPTokens / 2) >= tokenAmount / 2 - 10 ** 10);
    }
    function test_getToken0FromLiquidity_lp_amount_larger_than_supply() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initRAIETHPairLiquidity : initETHRAIPairLiquidity;
        assertEq(liquidityManager.getToken0FromLiquidity(initialLPTokens * 2), 0);
    }

    function test_getToken1FromLiquidity_zero() public {
        assertEq(liquidityManager.getToken1FromLiquidity(0), 0);
    }
    function test_getToken1FromLiquidity() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initETHRAIPairLiquidity : initRAIETHPairLiquidity;
        assertTrue(liquidityManager.getToken1FromLiquidity(initialLPTokens) >= tokenAmount - 10 ** 10);
        assertTrue(liquidityManager.getToken1FromLiquidity(initialLPTokens / 2) >= tokenAmount / 2 - 10 ** 10);
    }
    function test_getToken1FromLiquidity_lp_amount_larger_than_supply() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initETHRAIPairLiquidity : initRAIETHPairLiquidity;
        assertEq(liquidityManager.getToken1FromLiquidity(initialLPTokens * 2), 0);
    }

    function test_getLiquidityFromToken0_zero() public {
        assertEq(liquidityManager.getLiquidityFromToken0(0), 0);
    }
    function test_getLiquidityFromToken0() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initRAIETHPairLiquidity : initETHRAIPairLiquidity;
        DSToken token0 = DSToken((isSystemCoinToken0) ? address(systemCoin) : address(weth));
        uint256 currentTokenSupply = token0.balanceOf(address(this));
        uint256 lpTokens = liquidityManager.getLiquidityFromToken0(tokenAmount / 2);

        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(lpTokens, 1, 1, address(this));

        assertEq(token0.balanceOf(address(this)) - currentTokenSupply, tokenAmount / 2);
    }
    function test_getLiquidityFromToken0_token_amount_larger_than_pool_supply() public {
        assertEq(liquidityManager.getLiquidityFromToken0(uint(-1)), 0);
    }

    function test_getLiquidityFromToken1_zero() public {
        assertEq(liquidityManager.getLiquidityFromToken1(0), 0);
    }
    function test_getLiquidityFromToken1() public {
        uint256 tokenAmount = (isSystemCoinToken0) ? initETHRAIPairLiquidity : initRAIETHPairLiquidity;
        DSToken token1 = DSToken((isSystemCoinToken0) ? address(weth) : address(systemCoin));
        uint256 currentTokenSupply = token1.balanceOf(address(this));
        uint256 lpTokens = liquidityManager.getLiquidityFromToken1(tokenAmount / 2);

        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(lpTokens, 1, 1, address(this));

        assertEq(token1.balanceOf(address(this)) - currentTokenSupply, tokenAmount / 2);
    }
    function test_getLiquidityFromToken1_token_amount_larger_than_pool_supply() public {
        assertEq(liquidityManager.getLiquidityFromToken1(uint(-1)), 0);
    }

    function test_remove_some_liquidity() public {
        uint256 currentWETHSupply = weth.balanceOf(address(this));
        uint256 currentSysCoinSupply = systemCoin.balanceOf(address(this));

        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(initialLPTokens / 2, 1, 1, address(this));

        assertEq(systemCoin.balanceOf(address(liquidityManager)), 0);
        assertEq(weth.balanceOf(address(liquidityManager)), 0);
        assertEq(raiWETHPair.balanceOf(address(liquidityManager)), 0);

        uint256 wethWithdrawn = weth.balanceOf(address(this)) - currentWETHSupply;
        uint256 sysCoinWithdrawn = systemCoin.balanceOf(address(this)) - currentSysCoinSupply;

        assertTrue(wethWithdrawn > 0 && sysCoinWithdrawn > 0);
    }
    function test_remove_all_liquidity() public {
        uint256 currentWETHSupply = weth.balanceOf(address(this));
        uint256 currentSysCoinSupply = systemCoin.balanceOf(address(this));

        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(initialLPTokens, 1, 1, address(this));

        assertEq(systemCoin.balanceOf(address(liquidityManager)), 0);
        assertEq(weth.balanceOf(address(liquidityManager)), 0);
        assertEq(raiWETHPair.balanceOf(address(liquidityManager)), 0);

        uint256 wethWithdrawn = weth.balanceOf(address(this)) - currentWETHSupply;
        uint256 sysCoinWithdrawn = systemCoin.balanceOf(address(this)) - currentSysCoinSupply;

        assertTrue(wethWithdrawn > 0 && sysCoinWithdrawn > 0);
        assertEq(raiWETHPair.totalSupply(), 1000);
    }
    function testFail_remove_liquidity_token0_min_too_big() public {
        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(initialLPTokens, uint128(-1), 1, address(this));
    }
    function testFail_remove_liquidity_token1_min_too_big() public {
        raiWETHPair.approve(address(liquidityManager), uint(-1));
        liquidityManager.removeLiquidity(initialLPTokens, 1, uint128(-1), address(this));
    }
}
