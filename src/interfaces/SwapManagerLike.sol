pragma solidity 0.6.7;

abstract contract SwapManagerLike {
    function swap(
      address tokenIn,
      address tokenOut,
      uint amountIn,
      uint amountOutMin,
      address to
    ) external virtual returns (uint256 amountOut);

    function getAmountOut(address tokenIn, address tokenOut, uint amountIn) public virtual view returns (uint256);
}
