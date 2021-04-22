pragma solidity 0.6.7;

abstract contract UniswapLiquidityManagerLike {
    function getToken0FromLiquidity(uint256) virtual public view returns (uint256);
    function getToken1FromLiquidity(uint256) virtual public view returns (uint256);

    function getLiquidityFromToken0(uint256) virtual public view returns (uint256);
    function getLiquidityFromToken1(uint256) virtual public view returns (uint256);

    function removeLiquidity(
      uint256 liquidity,
      uint128 amount0Min,
      uint128 amount1Min,
      address to
    ) public virtual returns (uint256, uint256);
}
