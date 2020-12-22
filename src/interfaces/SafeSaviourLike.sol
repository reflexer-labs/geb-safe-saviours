pragma solidity 0.6.7;

import "./CollateralJoinLike.sol";
import "./OracleRelayerLike.sol";
import "./SAFEEngineLike.sol";
import "./LiquidationEngineLike.sol";
import "./PriceFeedLike.sol";
import "./ERC20Like.sol";
import "./GebSafeManagerLike.sol";
import "./SAFESaviourRegistryLike.sol";

abstract contract SafeSaviourLike {
    // Checks whether a saviour contract has been approved by governance in the LiquidationEngine
    modifier liquidationEngineApproved(address saviour) {
        require(liquidationEngine.safeSaviours(saviour) == 1, "SafeSaviour/not-approved-in-liquidation-engine");
        _;
    }
    // Checks whether someone controls a safe handler inside the GebSafeManager
    modifier controlsHandler(address owner, uint256 safeID) {
        require(owner != address(0), "SafeSaviour/null-owner");
        require(either(owner == safeManager.ownsSAFE(safeID), safeManager.safeCan(safeManager.ownsSAFE(safeID), safeID, owner) == 1), "SafeSaviour/not-owning-safe");

        _;
    }

    // --- Variables ---
    LiquidationEngineLike   public liquidationEngine;
    OracleRelayerLike       public oracleRelayer;
    GebSafeManagerLike      public safeManager;
    SAFEEngineLike          public safeEngine;
    SAFESaviourRegistryLike public saviourRegistry;

    // The amount of tokens the keeper gets in exchange for the gas spent to save a SAFE
    uint256 public keeperPayout;
    // The minimum fiat value that the keeper must get in exchange for saving a SAFE
    uint256 public minKeeperPayoutValue;
    /*
      The proportion between the keeperPayout and the amount of collateral that's in the SAFE to be saved. It ensures there's no
      incentive to put a SAFE underwater and then save it just to make a profit
    */
    uint256 public payoutToSAFESize;
    // The default collateralization ratio a SAFE should have after it's saved
    uint256 public defaultDesiredCollateralizationRatio;

    // Desired CRatios for each SAFE after they're saved
    mapping(bytes32 => mapping(address => uint256)) public desiredCollateralizationRatios;

    // --- Constants ---
    uint256 public constant ONE               = 1;
    uint256 public constant HUNDRED           = 100;
    uint256 public constant THOUSAND          = 1000;
    uint256 public constant CRATIO_SCALE_DOWN = 10**25;
    uint256 public constant WAD               = 10**18;
    uint256 public constant RAY               = 10**27;
    uint256 public constant MAX_CRATIO        = 1000;
    uint256 public constant MAX_UINT          = uint(-1);

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y) }
    }
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Functions to Implement ---
    function saveSAFE(address,bytes32,address) virtual external returns (bool,uint256,uint256);
    function keeperPayoutExceedsMinValue() virtual public returns (bool);
    function canSave(address) virtual external returns (bool);
    function tokenAmountUsedToSave(address) virtual public returns (uint256);
}
