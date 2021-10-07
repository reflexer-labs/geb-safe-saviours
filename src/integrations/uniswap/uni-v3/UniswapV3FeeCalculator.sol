pragma solidity 0.6.7;

import "../../../interfaces/UniswapV3NonFungiblePositionManagerLike.sol";
import "../../../interfaces/UniswapV3PoolLike.sol";

import "./FixedPoint128.sol";
import "./FullMath.sol";

contract UniswapV3FeeCalculator {
    // --- Variables ---
    // Uniswap v3 position manager
    UniswapV3NonFungiblePositionManagerLike public positionManager;

    constructor(
        address positionManager_
    ) public {
        require(positionManager_ != address(0), "UniswapV3FeeCalculator/null-position-manager");
        positionManager = UniswapV3NonFungiblePositionManagerLike(positionManager_);
    }

   // --- Core Logic ---
   /**
    * @notice Return the amount of uncollected fees for a specific position
    * @param pool Address of the pool associated with this position
    * @param tokenId The ID of the position in the manager
    */
   function getUncollectedFees(
      address pool,
      uint256 tokenId
   )
      external
      view
      returns (uint256, uint256)
   {
       ( ,,,,,
         int24 tickLower,
         int24 tickUpper,
         uint128 liquidity,
         uint256 oldFeeGrowthInside0LastX128,
         uint256 oldFeeGrowthInside1LastX128,
         ,
       )
        = positionManager.positions(tokenId);
       IUniswapV3Pool pool = UniswapV3PoolLike(pool);

       if (liquidity > 0) {
          uint256 amount0;
          uint256 amount1;

           (, uint256 latestFeeGrowthInside0LastX128, uint256 latestFeeGrowthInside1LastX128, , ) =
               pool.positions(PositionKey.compute(address(positionManager), tickLower, tickUpper));

           amount0 = uint256(
               FullMath.mulDiv(
                   latestFeeGrowthInside0LastX128 - oldFeeGrowthInside0LastX128,
                   liquidity,
                   FixedPoint128.Q128
               )
           );
           amount1 = uint256(
               FullMath.mulDiv(
                   latestFeeGrowthInside1LastX128 - oldFeeGrowthInside1LastX128,
                   liquidity,
                   FixedPoint128.Q128
               )
           );

           return (amount0, amount1);
       }

       return (0, 0);
    }
}
