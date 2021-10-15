pragma solidity >=0.6.7;
pragma experimental ABIEncoderV2;

import "../../../interfaces/ERC20Like.sol";
import "../../../interfaces/UniswapV3NonFungiblePositionManagerLike.sol";

import "../../../math/SafeMath.sol";
import "../../../utils/ReentrancyGuard.sol";

abstract contract PositionManager is UniswapV3NonFungiblePositionManagerLike {
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

contract UniswapV3LiquidityRemover is ReentrancyGuard, SafeMath {
    // --- Variables ---
    PositionManager positionManager;

    constructor(address positionManager_) public {
        require(positionManager_ != address(0), "UniswapV3LiquidityRemover/null-manager");
        positionManager = PositionManager(positionManager_);
    }

    // --- Internal Logic ---
    function getPositionDetails(uint256 tokenId) internal view returns (address, address, uint128) {
        ( ,,
          address token0,
          address token1,
          ,,,
          uint128 liquidity
        ) = positionManager.positions(tokenId);

        return (token0, token1, liquidity);
    }

    // --- Core Logic ---
    /**
     * @notice Remove all liquidity from a position and collect all its fees
     * @param tokenId The ID of the position from which we withdraw liquidity
     */
    function removeAllLiquidity(uint256 tokenId) external nonReentrant {
        // Transfer the position to this contract
        positionManager.transferFrom(msg.sender, address(this), tokenId);

        // Collect fees
        positionManager.collect(
          PositionManager.CollectParams(
            tokenId, msg.sender, uint128(-1), uint128(-1)
          )
        );

        // Withdraw liquidity next
        (address token0, address token1, uint128 liquidity) = getPositionDetails(tokenId);

        positionManager.decreaseLiquidity(
          PositionManager.DecreaseLiquidityParams(
            tokenId, liquidity, 0, 0, block.timestamp
          )
        );

        // Send collected tokens to the caller
        {
          if (ERC20Like(token0).balanceOf(address(this)) > 0) {
            require(ERC20Like(token0).transfer(msg.sender, ERC20Like(token0).balanceOf(address(this))), "UniswapV3LiquidityRemover/cannot-transfer-token0");
          }
          if (ERC20Like(token1).balanceOf(address(this)) > 0) {
            require(ERC20Like(token1).transfer(msg.sender, ERC20Like(token1).balanceOf(address(this))), "UniswapV3LiquidityRemover/cannot-transfer-token1");
          }
        }

        // Transfer the position back to the caller
        positionManager.transferFrom(address(this), msg.sender, tokenId);
    }
}
