pragma solidity 0.6.7;

import "../../../math/SafeMath.sol";
import "../../../interfaces/UniswapLiquidityManagerLike.sol";

abstract contract GebUniswapV3LiquidityManager {
    function getToken0FromLiquidity(uint256) virtual public view returns (uint256);
    function getToken1FromLiquidity(uint256) virtual public view returns (uint256);
    function getLiquidityFromToken0(uint256) virtual public view returns (uint256);
    function getLiquidityFromToken1(uint256) virtual public view returns (uint256);
    function withdraw(uint256, address, uint128, uint128) virtual external returns (uint256, uint256);
}

contract UniswapV3LiquidityManager is UniswapLiquidityManagerLike, SafeMath {
    GebUniswapV3LiquidityManager public gebLiquidityManager;

    constructor(address gebLiquidityManager_) public {
        require(gebLiquidityManager_ != address(0), "UniswapV3LiquidityManager/null-manager");
        gebLiquidityManager = GebUniswapV3LiquidityManager(gebLiquidityManager_);
    }

    // --- Public Getters ---
    /*
    * @notice Return the amount of token0 tokens that someone would get back by burning a specific amount of LP tokens
    * @param liquidityAmount The amount of LP tokens to burn
    * @return The amount of token0 tokens that someone would get back
    */
    function getToken0FromLiquidity(uint256 liquidityAmount) public override view returns (uint256) {
        if (liquidityAmount == 0) return 0;
        return gebLiquidityManager.getToken0FromLiquidity(liquidityAmount);
    }
    /*
    * @notice Return the amount of token1 tokens that someone would get back by burning a specific amount of LP tokens
    * @param liquidityAmount The amount of LP tokens to burn
    * @return The amount of token1 tokens that someone would get back
    */
    function getToken1FromLiquidity(uint256 liquidityAmount) public override view returns (uint256) {
        if (liquidityAmount == 0) return 0;
        return gebLiquidityManager.getToken1FromLiquidity(liquidityAmount);
    }
    /*
    * @notice Return the amount of LP tokens needed to withdraw a specific amount of token0 tokens
    * @param token0Amount The amount of token0 tokens from which to determine the amount of LP tokens
    * @return The amount of LP tokens needed to withdraw a specific amount of token0 tokens
    */
    function getLiquidityFromToken0(uint256 token0Amount) public override view returns (uint256) {
        if (token0Amount == 0) return 0;
        return gebLiquidityManager.getLiquidityFromToken0(token0Amount);
    }
    /*
    * @notice Return the amount of LP tokens needed to withdraw a specific amount of token1 tokens
    * @param token1Amount The amount of token1 tokens from which to determine the amount of LP tokens
    * @return The amount of LP tokens needed to withdraw a specific amount of token1 tokens
    */
    function getLiquidityFromToken1(uint256 token1Amount) public override view returns (uint256) {
        if (token1Amount == 0) return 0;
        return gebLiquidityManager.getLiquidityFromToken1(token1Amount);
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
        (amount0, amount1) = gebLiquidityManager.withdraw(
          liquidity,
          to,
          amount0Min,
          amount1Min
        );
    }
}
