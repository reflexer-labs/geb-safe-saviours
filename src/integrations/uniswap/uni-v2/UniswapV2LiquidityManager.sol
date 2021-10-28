pragma solidity >=0.6.7;

import "../uni-v2/interfaces/IUniswapV2Pair.sol";
import "../uni-v2/interfaces/IUniswapV2Router02.sol";

import "../../../math/SafeMath.sol";

import "../../../interfaces/ERC20Like.sol";
import "../../../interfaces/UniswapLiquidityManagerLike.sol";

contract UniswapV2LiquidityManager is UniswapLiquidityManagerLike, SafeMath {
    // The Uniswap v2 pair handled by this contract
    IUniswapV2Pair     public pair;
    // The official Uniswap v2 router V2
    IUniswapV2Router02 public router;

    constructor(address pair_, address router_) public {
        require(pair_ != address(0), "UniswapV2LiquidityManager/null-pair");
        require(router_ != address(0), "UniswapV2LiquidityManager/null-router");
        pair   = IUniswapV2Pair(pair_);
        router = IUniswapV2Router02(router_);
    }

    // --- Boolean Logic ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Public Getters ---
    /*
    * @notice Return the amount of token0 tokens that someone would get back by burning a specific amount of LP tokens
    * @param liquidityAmount The amount of LP tokens to burn
    * @return The amount of token0 tokens that someone would get back
    */
    function getToken0FromLiquidity(uint256 liquidityAmount) public override view returns (uint256) {
        if (liquidityAmount == 0) return 0;

        (uint256 totalSupply, uint256 cumulativeLPBalance) = getSupplyAndCumulativeLiquidity(liquidityAmount);
        if (either(liquidityAmount == 0, cumulativeLPBalance > totalSupply)) return 0;

        return mul(cumulativeLPBalance, ERC20Like(pair.token0()).balanceOf(address(pair))) / totalSupply;
    }
    /*
    * @notice Return the amount of token1 tokens that someone would get back by burning a specific amount of LP tokens
    * @param liquidityAmount The amount of LP tokens to burn
    * @return The amount of token1 tokens that someone would get back
    */
    function getToken1FromLiquidity(uint256 liquidityAmount) public override view returns (uint256) {
        if (liquidityAmount == 0) return 0;

        (uint256 totalSupply, uint256 cumulativeLPBalance) = getSupplyAndCumulativeLiquidity(liquidityAmount);
        if (either(liquidityAmount == 0, cumulativeLPBalance > totalSupply)) return 0;

        return mul(cumulativeLPBalance, ERC20Like(pair.token1()).balanceOf(address(pair))) / totalSupply;
    }
    /*
    * @notice Return the amount of LP tokens needed to withdraw a specific amount of token0 tokens
    * @param token0Amount The amount of token0 tokens from which to determine the amount of LP tokens
    * @return The amount of LP tokens needed to withdraw a specific amount of token0 tokens
    */
    function getLiquidityFromToken0(uint256 token0Amount) public override view returns (uint256) {
        if (either(token0Amount == 0, ERC20Like(address(pair.token0())).balanceOf(address(pair)) < token0Amount)) return 0;
        return div(mul(token0Amount, pair.totalSupply()), ERC20Like(pair.token0()).balanceOf(address(pair)));
    }
    /*
    * @notice Return the amount of LP tokens needed to withdraw a specific amount of token1 tokens
    * @param token1Amount The amount of token1 tokens from which to determine the amount of LP tokens
    * @return The amount of LP tokens needed to withdraw a specific amount of token1 tokens
    */
    function getLiquidityFromToken1(uint256 token1Amount) public override view returns (uint256) {
        if (either(token1Amount == 0, ERC20Like(address(pair.token1())).balanceOf(address(pair)) < token1Amount)) return 0;
        return div(mul(token1Amount, pair.totalSupply()), ERC20Like(pair.token1()).balanceOf(address(pair)));
    }

    // --- Internal Getters ---
    /*
    * @notice Internal view function that returns the total supply of LP tokens in the 'pair' as well as the LP
    *         token balance of the pair contract itself if it were to have liquidityAmount extra tokens
    * @param liquidityAmount The amount of LP tokens that would be burned
    * @return The total supply of LP tokens in the 'pair' as well as the LP token balance
    *         of the pair contract itself if it were to have liquidityAmount extra tokens
    */
    function getSupplyAndCumulativeLiquidity(uint256 liquidityAmount) internal view returns (uint256, uint256) {
        return (pair.totalSupply(), add(pair.balanceOf(address(pair)), liquidityAmount));
    }

    // --- Liquidity Removal Logic ---
    /*
    * @notice Remove liquidity from the Uniswap pool
    * @param liquidity The amount of LP tokens to burn
    * @param amount0Min The min amount of token0 requested
    * @param amount1Min The min amount of token1 requested
    * @param to The address that receives token0 and token1 tokens after liquidity is removed
    * @return The amounts of token0 and token1 tokens returned
    */
    function removeLiquidity(
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        address to
    ) public override returns (uint256 amount0, uint256 amount1) {
        require(to != address(0), "UniswapV2LiquidityManager/null-dst");
        pair.transferFrom(msg.sender, address(this), liquidity);
        pair.approve(address(router), liquidity);
        (amount0, amount1) = router.removeLiquidity(
          pair.token0(),
          pair.token1(),
          liquidity,
          uint(amount0Min),
          uint(amount1Min),
          to,
          now
        );
    }
}
