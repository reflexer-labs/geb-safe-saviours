pragma solidity 0.6.7;

import "./OracleRelayerLike.sol";
import "./GebSafeManagerLike.sol";

import "../utils/ReentrancyGuard.sol";

abstract contract SaviourCRatioSetterLike is ReentrancyGuard {
    // --- Auth ---
    mapping (address => uint256) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "SaviourCRatioSetter/account-not-authorized");
        _;
    }

    // Checks whether someone controls a safe handler inside the GebSafeManager
    modifier controlsSAFE(address owner, uint256 safeID) {
        require(owner != address(0), "SaviourCRatioSetter/null-owner");
        require(either(owner == safeManager.ownsSAFE(safeID), safeManager.safeCan(safeManager.ownsSAFE(safeID), safeID, owner) == 1), "SaviourCRatioSetter/not-owning-safe");

        _;
    }

    // --- Variables ---
    OracleRelayerLike  public oracleRelayer;
    GebSafeManagerLike public safeManager;

    // Default desired cratio for each individual collateral type
    mapping(bytes32 => uint256)                     public defaultDesiredCollateralizationRatios;
    // Minimum bound for the desired cratio for each collateral type
    mapping(bytes32 => uint256)                     public minDesiredCollateralizationRatios;
    // Desired CRatios for each SAFE after they're saved
    mapping(bytes32 => mapping(address => uint256)) public desiredCollateralizationRatios;

    // --- Constants ---
    uint256 public constant MAX_CRATIO        = 1000;
    uint256 public constant CRATIO_SCALE_DOWN = 10**25;

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y) }
    }
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event SetDefaultCRatio(bytes32 indexed collateralType, uint256 cRatio);
    event SetMinDesiredCollateralizationRatio(
      bytes32 indexed collateralType,
      uint256 cRatio
    );
    event SetDesiredCollateralizationRatio(
      address indexed caller,
      bytes32 indexed collateralType,
      uint256 safeID,
      address indexed safeHandler,
      uint256 cRatio
    );

    // --- Functions ---
    function setDefaultCRatio(bytes32, uint256) virtual external;
    function setMinDesiredCollateralizationRatio(bytes32 collateralType, uint256 cRatio) virtual external;
    function setDesiredCollateralizationRatio(bytes32 collateralType, uint256 safeID, uint256 cRatio) virtual external;
}
