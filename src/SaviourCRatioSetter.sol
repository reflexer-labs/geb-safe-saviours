pragma solidity >=0.6.7;

import "./interfaces/SaviourCRatioSetterLike.sol";
import "./math/SafeMath.sol";

contract SaviourCRatioSetter is SafeMath, SaviourCRatioSetterLike {
    constructor(
      address oracleRelayer_,
      address safeManager_
    ) public {
        require(oracleRelayer_ != address(0), "SaviourCRatioSetter/null-oracle-relayer");
        require(safeManager_ != address(0), "SaviourCRatioSetter/null-safe-manager");

        authorizedAccounts[msg.sender] = 1;

        oracleRelayer = OracleRelayerLike(oracleRelayer_);
        safeManager   = GebSafeManagerLike(safeManager_);

        oracleRelayer.redemptionPrice();

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
    }

    // --- Administration ---
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "SaviourCRatioSetter/null-data");

        if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else revert("SaviourCRatioSetter/modify-unrecognized-param");
    }
    /**
     * @notice Set the default desired CRatio for a specific collateral type
     * @param collateralType The name of the collateral type to set the default CRatio for
     * @param cRatio New default collateralization ratio
     */
    function setDefaultCRatio(bytes32 collateralType, uint256 cRatio) external override isAuthorized {
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralType) / CRATIO_SCALE_DOWN;

        require(scaledLiquidationRatio > 0, "SaviourCRatioSetter/invalid-scaled-liq-ratio");
        require(both(cRatio > scaledLiquidationRatio, cRatio <= MAX_CRATIO), "SaviourCRatioSetter/invalid-default-desired-cratio");

        defaultDesiredCollateralizationRatios[collateralType] = cRatio;

        emit SetDefaultCRatio(collateralType, cRatio);
    }
    /*
    * @notify Set the minimum CRatio that every Safe must take into account when setting a desired CRatio
    * @param collateralType The collateral type for which to set the min desired CRatio
    * @param cRatio The min desired CRatio to set for collateralType
    */
    function setMinDesiredCollateralizationRatio(bytes32 collateralType, uint256 cRatio) external override isAuthorized {
        require(cRatio < MAX_CRATIO, "SaviourCRatioSetter/invalid-min-cratio");
        minDesiredCollateralizationRatios[collateralType] = cRatio;
        emit SetMinDesiredCollateralizationRatio(collateralType, cRatio);
    }
    // --- Adjust Cover Preferences ---
    /*
    * @notice Sets the collateralization ratio that a SAFE should have after it's saved
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param collateralType The collateral type used in the safe
    * @param safeID The ID of the SAFE to set the desired CRatio for. This ID should be registered inside GebSafeManager
    * @param cRatio The collateralization ratio to set
    */
    function setDesiredCollateralizationRatio(bytes32 collateralType, uint256 safeID, uint256 cRatio)
      external override controlsSAFE(msg.sender, safeID) {
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralType) / CRATIO_SCALE_DOWN;
        address safeHandler = safeManager.safes(safeID);

        require(scaledLiquidationRatio > 0, "SaviourCRatioSetter/invalid-scaled-liq-ratio");
        require(either(cRatio >= minDesiredCollateralizationRatios[collateralType], cRatio == 0), "SaviourCRatioSetter/invalid-min-ratio");
        require(cRatio <= MAX_CRATIO, "SaviourCRatioSetter/exceeds-max-cratio");

        if (cRatio > 0) {
            require(scaledLiquidationRatio < cRatio, "SaviourCRatioSetter/invalid-desired-cratio");
        }

        desiredCollateralizationRatios[collateralType][safeHandler] = cRatio;

        emit SetDesiredCollateralizationRatio(msg.sender, collateralType, safeID, safeHandler, cRatio);
    }
}
