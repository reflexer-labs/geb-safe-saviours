pragma solidity 0.6.7;

import "../uni-v2/interfaces/IUniswapV2Router02.sol";
import "../uni-v2/interfaces/IUniswapV2Factory.sol";
import "../uni-v2/interfaces/IUniswapV2Pair.sol";

import "../../../math/SafeMath.sol";

import "../../../interfaces/ERC20Like.sol";
import "../../../interfaces/SwapManagerLike.sol";

import "../../../utils/ReentrancyGuard.sol";

contract UniswapV2Swapper is ReentrancyGuard, SwapManagerLike {
    // --- Variables ---
    // The official Uniswap v2 router V2
    IUniswapV2Router02 public router;
    // The official Uniswap v2 factory
    IUniswapV2Factory public factory;
    // Array of tokens to be swapped
    address[] tokenPath;

    constructor(address factory_, address router_) public {
        require(factory_ != address(0), "UniswapV2Swapper/null-factory");
        require(router_ != address(0), "UniswapV2Swapper/null-router");

        factory = IUniswapV2Factory(factory_);
        router  = IUniswapV2Router02(router_);
    }

    // --- Math ---
    function uniAddition(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'UniswapV2Swapper/add-overflow');
    }
    function uniSubtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'UniswapV2Swapper/sub-underflow');
    }
    function uniMultiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'UniswapV2Swapper/mul-overflow');
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Core Logic ---
    /*
    * @notice Swap from one token to another
    * @param tokenIn The token that's being sold
    * @param tokenOut The token that's being bought
    * @param amountIn The amount of tokens being sold
    * @param amountOutMin The minimum amount of tokens being bought
    * @param to The address that will receive the bought tokens
    */
    function swap(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint amountOutMin,
        address to
    ) external override nonReentrant returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Swapper/null-amount-in");
        require(to != address(0), "UniswapV2Swapper/null-dst");

        ERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20Like(tokenIn).approve(address(router), amountIn);

        tokenPath.push(tokenIn);
        tokenPath.push(tokenOut);

        router.swapExactTokensForTokens(amountIn, 1, tokenPath, to, now);
        delete(tokenPath);
    }

    // --- Public Getters ---
    /*
    * @notice Return the amount of tokens bought given a specific pair and an amount of tokens being sold
    * @param tokenIn The token that's being sold
    * @param tokenOut The token that's being bought
    * @param amountIn The amount of tokens being sold
    * @return amountOut The amount of tokens that can be bought
    */
    function getAmountOut(address tokenIn, address tokenOut, uint amountIn) public override view returns (uint256 amountOut) {
        require(amountIn > 0, 'UniswapV2Swapper/null-amount-in');

        (uint reserveIn, uint reserveOut) = getReserves(tokenIn, tokenOut);
        require(both(reserveIn > 0, reserveOut > 0), 'UniswapV2Swapper/insufficient-liquidity');

        uint amountInWithFee = uniMultiply(amountIn, 997);
        uint numerator       = uniMultiply(amountInWithFee, reserveOut);
        uint denominator     = uniAddition(uniMultiply(reserveIn, 1000), amountInWithFee);
        amountOut = numerator / denominator;
    }
    /*
    * @notice Return the length of the tokenPath array
    */
    function getTokenPathLength() public view returns (uint256) {
        return tokenPath.length;
    }

    // --- Internal Logic ---
    /*
    * @notice Returns sorted token addresses, used to handle return values from pairs sorted in this order
    * @param tokenA One of the tokens in a pair
    * @param tokenB A second token in a pair
    */
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Swapper/identical-tokens');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Swapper/null-token');
    }

    /*
    * @notice Return a pair address given two tokens
    * @param tokenA One of the tokens in a pair
    * @param tokenB A second token in a pair
    */
    function pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        return factory.getPair(tokenA, tokenB);
    }

    /*
    * @notice Fetches and sorts the reserves for a pair
    * @param tokenA One of the tokens in a pair
    * @param tokenB A second token in a pair
    */
    function getReserves(address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(factory.getPair(tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }
}
