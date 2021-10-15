pragma solidity >=0.6.7;

abstract contract UniswapV3LiquidityRemoverLike {
    function removeAllLiquidity(uint256 tokenId) external virtual;
}
