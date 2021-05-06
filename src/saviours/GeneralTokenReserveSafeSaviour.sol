// Copyright (C) 2020 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract GeneralTokenReserveSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "GeneralTokenReserveSafeSaviour/account-not-authorized");
        _;
    }

    mapping (address => uint256) public allowedUsers;
    /**
     * @notice Allow a user to deposit assets
     * @param usr User to whitelist
     */
    function allowUser(address usr) external isAuthorized {
        allowedUsers[usr] = 1;
        emit AllowUser(usr);
    }
    /**
     * @notice Disallow a user from depositing assets
     * @param usr User to disallow
     */
    function disallowUser(address usr) external isAuthorized {
        allowedUsers[usr] = 0;
        emit DisallowUser(usr);
    }
    /**
    * @notice Checks whether an address is an allowed user
    **/
    modifier isAllowed {
        require(
          either(restrictUsage == 0, both(restrictUsage == 1, allowedUsers[msg.sender] == 1)),
          "GeneralTokenReserveSafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                     public restrictUsage;

    // Amount of collateral deposited to cover each SAFE
    mapping(address => uint256) public collateralTokenCover;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike          public collateralJoin;
    // The collateral token
    ERC20Like                   public collateralToken;
    // Contract that defines desired CRatios for each Safe after it is saved
    SaviourCRatioSetterLike     public cRatioSetter;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event AllowUser(address usr);
    event DisallowUser(address usr);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event ModifyParameters(bytes32 indexed parameter, uint256 data);
    event Deposit(address indexed caller, address indexed safeHandler, uint256 amount);
    event Withdraw(address indexed caller, address indexed safeHandler, address dst, uint256 amount);

    constructor(
      address cRatioSetter_,
      address collateralJoin_,
      address liquidationEngine_,
      address taxCollector_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_,
      uint256 payoutToSAFESize_
    ) public {
        require(cRatioSetter_ != address(0), "GeneralTokenReserveSafeSaviour/null-cratio-setter");
        require(collateralJoin_ != address(0), "GeneralTokenReserveSafeSaviour/null-collateral-join");
        require(liquidationEngine_ != address(0), "GeneralTokenReserveSafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "GeneralTokenReserveSafeSaviour/null-tax-collector");
        require(oracleRelayer_ != address(0), "GeneralTokenReserveSafeSaviour/null-oracle-relayer");
        require(safeManager_ != address(0), "GeneralTokenReserveSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "GeneralTokenReserveSafeSaviour/null-saviour-registry");
        require(keeperPayout_ > 0, "GeneralTokenReserveSafeSaviour/invalid-keeper-payout");
        require(payoutToSAFESize_ > 1, "GeneralTokenReserveSafeSaviour/invalid-payout-to-safe-size");
        require(minKeeperPayoutValue_ > 0, "GeneralTokenReserveSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        keeperPayout         = keeperPayout_;
        payoutToSAFESize     = payoutToSAFESize_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        cRatioSetter         = SaviourCRatioSetterLike(cRatioSetter_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        taxCollector         = TaxCollectorLike(taxCollector_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        safeEngine           = SAFEEngineLike(collateralJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        collateralToken      = ERC20Like(collateralJoin.collateral());

        require(address(safeEngine) != address(0), "GeneralTokenReserveSafeSaviour/null-safe-engine");
        require(collateralJoin.decimals() == 18, "GeneralTokenReserveSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "GeneralTokenReserveSafeSaviour/join-disabled");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("keeperPayout", keeperPayout);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("cRatioSetter", cRatioSetter_);
        emit ModifyParameters("taxCollector", taxCollector_);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
    }

    // --- Administration ---
    /**
     * @notice Modify an uint256 param
     * @param parameter The name of the parameter
     * @param val New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "keeperPayout") {
            require(val > 0, "GeneralTokenReserveSafeSaviour/null-payout");
            keeperPayout = val;
        }
        else if (parameter == "minKeeperPayoutValue") {
            require(val > 0, "GeneralTokenReserveSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "GeneralTokenReserveSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("GeneralTokenReserveSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "GeneralTokenReserveSafeSaviour/null-data");

        if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "liquidationEngine") {
            liquidationEngine = LiquidationEngineLike(data);
        }
        else if (parameter == "taxCollector") {
            taxCollector = TaxCollectorLike(data);
        }
        else revert("GeneralTokenReserveSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit collateralToken in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param collateralTokenAmount The amount of collateralToken to deposit
    */
    function deposit(uint256 safeID, uint256 collateralTokenAmount) external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        require(collateralTokenAmount > 0, "GeneralTokenReserveSafeSaviour/null-collateralToken-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "GeneralTokenReserveSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "GeneralTokenReserveSafeSaviour/safe-does-not-have-debt");

        // Update the collateralToken balance used to cover the SAFE and transfer collateralToken to this contract
        collateralTokenCover[safeHandler] = add(collateralTokenCover[safeHandler], collateralTokenAmount);
        require(collateralToken.transferFrom(msg.sender, address(this), collateralTokenAmount), "GeneralTokenReserveSafeSaviour/could-not-transfer-collateralToken");

        emit Deposit(msg.sender, safeHandler, collateralTokenAmount);
    }
    /*
    * @notice Withdraw collateralToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param collateralTokenAmount The amount of collateralToken to withdraw
    * @param dst The address that will receive the withdrawn tokens
    */
    function withdraw(uint256 safeID, uint256 collateralTokenAmount, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(collateralTokenAmount > 0, "GeneralTokenReserveSafeSaviour/null-collateralToken-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(collateralTokenCover[safeHandler] >= collateralTokenAmount, "GeneralTokenReserveSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        collateralTokenCover[safeHandler] = sub(collateralTokenCover[safeHandler], collateralTokenAmount);
        collateralToken.transfer(dst, collateralTokenAmount);

        emit Withdraw(msg.sender, safeHandler, dst, collateralTokenAmount);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by adding more collateralToken into it
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of collateralToken added in the SAFE as well as the amount of
    *         collateralToken sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "GeneralTokenReserveSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "GeneralTokenReserveSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        require(collateralType == collateralJoin.collateralType(), "GeneralTokenReserveSafeSaviour/invalid-collateral-type");

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "GeneralTokenReserveSafeSaviour/small-keeper-payout-value");

        // Tax the collateral type
        taxCollector.taxSingle(collateralType);

        // Check that the amount of collateral locked in the safe is bigger than the keeper's payout
        (uint256 safeLockedCollateral,) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeLockedCollateral >= mul(keeperPayout, payoutToSAFESize), "GeneralTokenReserveSafeSaviour/tiny-safe");

        // Compute and check the validity of the amount of collateralToken used to save the SAFE
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralJoin.collateralType(), safeHandler);
        require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "GeneralTokenReserveSafeSaviour/invalid-tokens-used-to-save");

        // Check that there's enough collateralToken added as to cover both the keeper's payout and the amount used to save the SAFE
        require(collateralTokenCover[safeHandler] >= add(keeperPayout, tokenAmountUsed), "GeneralTokenReserveSafeSaviour/not-enough-cover-deposited");

        // Update the remaining cover
        collateralTokenCover[safeHandler] = sub(collateralTokenCover[safeHandler], add(keeperPayout, tokenAmountUsed));

        // Mark the SAFE in the registry as just being saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Approve collateralToken to the collateral join contract
        collateralToken.approve(address(collateralJoin), 0);
        collateralToken.approve(address(collateralJoin), tokenAmountUsed);

        // Join collateralToken in the system and add it in the saved SAFE
        collateralJoin.join(address(this), tokenAmountUsed);
        safeEngine.modifySAFECollateralization(
          collateralJoin.collateralType(),
          safeHandler,
          address(this),
          address(0),
          int256(tokenAmountUsed),
          int256(0)
        );

        // Send the fee to the keeper
        collateralToken.transfer(keeper, keeperPayout);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, tokenAmountUsed);

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    /*
    * @notice Compute whether the value of keeperPayout collateralToken is higher than or equal to minKeeperPayoutValue
    * @dev Used to determine whether it's worth it for the keeper to save the SAFE in exchange for keeperPayout collateralToken
    * @return A bool representing whether the value of keeperPayout collateralToken is >= minKeeperPayoutValue
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(PriceFeedLike(ethFSM).priceSource()).getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return false;
        }

        return (minKeeperPayoutValue <= mul(keeperPayout, priceFeedValue) / WAD);
    }
    /*
    * @notice Return the current value of the keeper payout
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(PriceFeedLike(ethFSM).priceSource()).getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return 0;
        }

        return mul(keeperPayout, priceFeedValue) / WAD;
    }
    /*
    * @notice Determine whether a SAFE can be saved with the current amount of collateralToken deposited as cover for it
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(bytes32, address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralJoin.collateralType(), safeHandler);

        if (either(tokenAmountUsed == MAX_UINT, tokenAmountUsed == 0)) {
            return false;
        }

        return (collateralTokenCover[safeHandler] >= add(tokenAmountUsed, keeperPayout));
    }
    /*
    * @notice Calculate the amount of collateralToken used to save a SAFE and bring its CRatio to the desired level
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of collateralToken used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(bytes32, address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        if (ethFSM == address(0)) return MAX_UINT;
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        // If the SAFE doesn't have debt, if the price feed is faulty or if the default desired CRatio is null, abort
        uint256 defaultCRatio = cRatioSetter.defaultDesiredCollateralizationRatios(collateralJoin.collateralType());
        if (either(either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue)), defaultCRatio == 0)) {
            tokenAmountUsed = MAX_UINT;
            return MAX_UINT;
        }

        // Calculate the value of the debt equivalent to the value of the collateralToken that would need to be in the SAFE after it's saved
        uint256 targetCRatio = (cRatioSetter.desiredCollateralizationRatios(collateralJoin.collateralType(), safeHandler) == 0) ?
          defaultCRatio : cRatioSetter.desiredCollateralizationRatios(collateralJoin.collateralType(), safeHandler);
        uint256 scaledDownDebtValue = mul(
          mul(oracleRelayer.redemptionPrice(), safeDebt) / RAY, getAccumulatedRate(collateralJoin.collateralType())
        ) / RAY;
        scaledDownDebtValue         = mul(add(scaledDownDebtValue, ONE), targetCRatio) / HUNDRED;

        // Compute the amount of collateralToken the SAFE needs to get to the desired CRatio
        uint256 collateralTokenAmountNeeded = mul(scaledDownDebtValue, WAD) / priceFeedValue;

        // If the amount of collateralToken needed is lower than the amount that's currently in the SAFE, return 0
        if (collateralTokenAmountNeeded <= depositedCollateralToken) {
          return 0;
        } else {
          // Otherwise return the delta
          return sub(collateralTokenAmountNeeded, depositedCollateralToken);
        }
    }
    /*
    * @notify Get the accumulated interest rate for a specific collateral type
    * @param The collateral type for which to retrieve the rate
    */
    function getAccumulatedRate(bytes32 collateralType)
      public view returns (uint256 accumulatedRate) {
        (, accumulatedRate, , , , ) = safeEngine.collateralTypes(collateralType);
    }
}
