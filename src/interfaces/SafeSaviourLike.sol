pragma solidity 0.6.7;

import "./CollateralJoinLike.sol";
import "./OracleRelayerLike.sol";
import "./SAFEEngineLike.sol";
import "./LiquidationEngineLike.sol";

abstract contract SafeSaviourLike {
    modifier liquidationEngineApproved(address saviour) {
        require(liquidationEngine.safeSaviours(saviour) == 1, "SafeSaviour/not-approved-in-liquidation-engine");
        _;
    }

    LiquidationEngineLike public liquidationEngine;
    OracleRelayerLike     public oracleRelayer;
    CollateralJoinLike    public collateralJoin;

    uint256 public minKeeperPayout;
    uint256 public maxKeeperPayout;
    uint256 public maxCreatorPayout;

    uint256 public creatorRewardPercentage;
    uint256 public keeperRewardPercentage;

    mapping(bytes32 => address) public desiredCollateralizationRatios;

    function saveSAFE(address,bytes32,address) virtual external returns (bool,uint256,uint256);
    function canSave(address) virtual external returns (bool);
}
