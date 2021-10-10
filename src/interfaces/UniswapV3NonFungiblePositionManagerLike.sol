pragma solidity >=0.6.7;
pragma experimental ABIEncoderV2;

import "./IERC721.sol";

abstract contract UniswapV3NonFungiblePositionManagerLike is IERC721 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

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
          uint128 liquidity,
          uint256 feeGrowthInside0LastX128,
          uint256 feeGrowthInside1LastX128,
          uint128 tokensOwed0,
          uint128 tokensOwed1
        );
    function collect(CollectParams calldata)
        external
        payable
        virtual
        returns (uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        virtual
        returns (uint256 amount0, uint256 amount1);
}
