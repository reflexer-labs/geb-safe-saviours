pragma solidity 0.6.7;

import "../../../math/SafeMath.sol";

abstract contract GebUniswapV3LiquidityManager {
    function getToken0FromLiquidity(uint256) virtual public view returns (uint256);
    function getToken1FromLiquidity(uint256) virtual public view returns (uint256);
    function getLiquidityFromToken0(uint256) virtual public view returns (uint256);
    function getLiquidityFromToken1(uint256) virtual public view returns (uint256);
    function transferFrom(address, address, uint256) virtual public returns (bool);
    function withdraw(uint256, address, uint128, uint128) virtual external returns (uint256, uint256);
}

contract UniswapV3LiquidityManager is SafeMath {
    GebUniswapV3LiquidityManager public gebLiquidityManager;

    constructor(address gebLiquidityManager_) public {
        require(gebLiquidityManager_ != address(0), "UniswapV3LiquidityManager/null-manager");
        gebLiquidityManager = GebUniswapV3LiquidityManager(gebLiquidityManager_);
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
    ) public returns (uint256 amount0, uint256 amount1) {
        require(to != address(0), "UniswapV3LiquidityManager/null-dst");
        gebLiquidityManager.transferFrom(msg.sender, address(this), liquidity);
        (amount0, amount1) = gebLiquidityManager.withdraw(
          liquidity,
          to,
          amount0Min,
          amount1Min
        );
    }
}
