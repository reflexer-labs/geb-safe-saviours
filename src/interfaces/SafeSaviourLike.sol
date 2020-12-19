pragma solidity 0.6.7;

import "./ETHJoinLike.sol";
import "./OracleRelayerLike.sol";
import "./SAFEEngineLike.sol";
import "./LiquidationEngineLike.sol";
import "./PriceFeedLike.sol";

abstract contract SafeSaviourLike {
    modifier liquidationEngineApproved(address saviour) {
        require(liquidationEngine.safeSaviours(saviour) == 1, "SafeSaviour/not-approved-in-liquidation-engine");
        _;
    }
    modifier controlsHandler(address owner, uint256 safeID) {
        require(owner != address(0), "SafeSaviour/null-owner");
        require(either(owner == safeManager.ownsSAFE(safeID), safeManager.safeCan(safeManager.ownsSAFE(safeID), safeID, owner) == 1), "SafeSaviour/not-owning-safe");

        _;
    }

    LiquidationEngineLike public liquidationEngine;
    OracleRelayerLike     public oracleRelayer;
    GebSafeManagerLike    public safeManager;

    uint256 public keeperPayout;
    uint256 public minKeeperPayoutValue;
    uint256 public payoutToSAFESize;
    uint256 public defaultDesiredCollateralizationRatio;

    mapping(bytes32 => uint256) public desiredCollateralizationRatios;

    // --- Constants ---
    uint256 public constant ONE               = 1;
    uint256 public constant HUNDRED           = 100;
    uint256 public constant THOUSAND          = 1000;
    uint256 public constant CRATIO_SCALE_DOWN = 10^16;
    uint256 public constant WAD               = 10^18;
    uint256 public constant RAY               = 10^27;
    uint256 public constant MAX_CRATIO        = 1500;
    uint256 public constant MAX_UINT          = uint(-1);

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y) }
    }
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    function saveSAFE(address,bytes32,address) virtual external returns (bool,uint256,uint256);
    function keeperPayoutExceedsMinValue() virtual public returns (bool);
    function canSave(address) virtual external returns (bool);
    function tokenAmountUsedToSave(address) virtual public returns (uint256);
}
