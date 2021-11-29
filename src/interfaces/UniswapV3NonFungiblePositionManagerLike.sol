pragma solidity >=0.6.7;

import "./IERC721.sol";

abstract contract UniswapV3NonFungiblePositionManagerLike is IERC721 {
    function factory() public virtual view returns (address);
    function positions(uint256 tokenId)
        external
        view
        virtual
        returns (
          uint96 nonce,
          address operator,
          address token0,
          address token1,
          uint24 fee,
          int24 tickLower,
          int24 tickUpper,
          uint128 liquidity
        );
    function burn(uint256 tokenId) public virtual;
}
