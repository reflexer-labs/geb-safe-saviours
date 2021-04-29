pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "../integrations/uniswap/uni-v2/UniswapV2Factory.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Pair.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Router02.sol";

import "../integrations/uniswap/swappers/UniswapV2Swapper.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract UniswapV2SwapManagerTest is DSTest {
    Hevm hevm;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;
    UniswapV2Swapper swapManager;

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

        // Swap manager
        swapManager = new UniswapV2Swapper(address(uniswapFactory), address(uniswapRouter));
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
    function test_setup() public {
        assertEq(address(swapManager.router()), address(uniswapRouter));
        assertEq(address(swapManager.factory()), address(uniswapFactory));
    }
    function testFail_swap_zero_amount() public {
        systemCoin.mint(address(this), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        swapManager.swap(address(systemCoin), address(weth), 0, 1, address(this));
    }
    function testFail_swap_inexistent_pair() public {
        systemCoin.mint(address(this), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        swapManager.swap(address(systemCoin), address(0x123), 1 ether, 1, address(this));
    }
    function testFail_target_destination_null() public {
        systemCoin.mint(address(this), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        swapManager.swap(address(systemCoin), address(weth), 1 ether, 1, address(0));
    }
    function testFail_swapper_cannot_pull_tokens() public {
        systemCoin.mint(address(this), 1 ether);

        swapManager.swap(address(systemCoin), address(weth), 1 ether, 1, address(this));
    }
    function test_swap_when_swapper_contains_tokens() public {
        weth.deposit{value: 1 ether}();
        weth.transfer(address(swapManager), 1 ether);

        systemCoin.mint(address(this), 2 ether);
        systemCoin.transfer(address(swapManager), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        uint256 currentWethBalance = weth.balanceOf(address(this));
        swapManager.swap(address(systemCoin), address(weth), 1 ether, 1, address(this));
        assertTrue(weth.balanceOf(address(this)) > currentWethBalance);

        assertEq(swapManager.getTokenPathLength(), 0);
    }
    function test_swap_rai_weth() public {
        systemCoin.mint(address(this), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        uint256 currentWethBalance = weth.balanceOf(address(this));
        swapManager.swap(address(systemCoin), address(weth), 1 ether, 1, address(this));
        assertTrue(weth.balanceOf(address(this)) > currentWethBalance);

        assertEq(swapManager.getTokenPathLength(), 0);
    }
    function test_swap_weth_rai() public {
        weth.deposit{value: 1 ether}();
        weth.approve(address(swapManager), uint(-1));

        uint256 currentSysCoinBalance = systemCoin.balanceOf(address(this));
        swapManager.swap(address(weth), address(systemCoin), 1 ether, 1, address(this));
        assertTrue(systemCoin.balanceOf(address(this)) > currentSysCoinBalance);

        assertEq(swapManager.getTokenPathLength(), 0);
    }
    function testFail_getAmountOut_null_amount_in() public {
        swapManager.getAmountOut(address(systemCoin), address(weth), 0);
    }
    function testFail_getAmountOut_inexistent_pair() public {
        swapManager.getAmountOut(address(systemCoin), address(0x123), 1 ether);
    }
    function test_getAmountOut_rai_weth() public {
        uint256 amountOut = swapManager.getAmountOut(address(systemCoin), address(weth), 1 ether);

        systemCoin.mint(address(this), 1 ether);
        systemCoin.approve(address(swapManager), uint(-1));

        uint256 currentWethBalance = weth.balanceOf(address(this));
        swapManager.swap(address(systemCoin), address(weth), 1 ether, 1, address(this));
        assertEq(weth.balanceOf(address(this)) - currentWethBalance, amountOut);

        assertEq(swapManager.getTokenPathLength(), 0);
    }
    function test_getAmountOut_weth_rai() public {
        uint256 amountOut = swapManager.getAmountOut(address(weth), address(systemCoin), 1 ether);

        weth.deposit{value: 1 ether}();
        weth.approve(address(swapManager), uint(-1));

        uint256 currentSysCoinBalance = systemCoin.balanceOf(address(this));
        swapManager.swap(address(weth), address(systemCoin), 1 ether, 1, address(this));
        assertEq(systemCoin.balanceOf(address(this)) - currentSysCoinBalance, amountOut);

        assertEq(swapManager.getTokenPathLength(), 0);
    }
    function testFail_getAmountOut_amount_in_higher_than_pool_balance() public {
        uint256 amountOut = swapManager.getAmountOut(address(weth), address(systemCoin), 1E45);

        weth.deposit{value: 1E45}();
        weth.approve(address(swapManager), uint(-1));

        uint256 currentSysCoinBalance = systemCoin.balanceOf(address(this));
        swapManager.swap(address(weth), address(systemCoin), 1E45, 1, address(this));
        assertEq(systemCoin.balanceOf(address(this)) - currentSysCoinBalance, amountOut);
    }
}
