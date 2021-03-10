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

import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract GeneralTokenReserveSafeSaviour is SafeMath, SafeSaviourLike {
    // --- Variables ---
    // Amount of collateral deposited to cover each SAFE
    mapping(address => uint256) public collateralTokenCover;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike          public collateralJoin;
    // The collateral token
    ERC20Like                   public collateralToken;

    // --- Events ---
    event Deposit(address indexed caller, address indexed safeHandler, uint256 amount);
    event Withdraw(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 amount);

    constructor(
      address collateralJoin_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_,
      uint256 payoutToSAFESize_,
      uint256 defaultDesiredCollateralizationRatio_
    ) public {
        require(collateralJoin_ != address(0), "GeneralTokenReserveSafeSaviour/null-collateral-join");
        require(liquidationEngine_ != address(0), "GeneralTokenReserveSafeSaviour/null-liquidation-engine");
        require(oracleRelayer_ != address(0), "GeneralTokenReserveSafeSaviour/null-oracle-relayer");
        require(safeManager_ != address(0), "GeneralTokenReserveSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "GeneralTokenReserveSafeSaviour/null-saviour-registry");
        require(keeperPayout_ > 0, "GeneralTokenReserveSafeSaviour/invalid-keeper-payout");
        require(defaultDesiredCollateralizationRatio_ > 0, "GeneralTokenReserveSafeSaviour/null-default-cratio");
        require(payoutToSAFESize_ > 1, "GeneralTokenReserveSafeSaviour/invalid-payout-to-safe-size");
        require(minKeeperPayoutValue_ > 0, "GeneralTokenReserveSafeSaviour/invalid-min-payout-value");

        keeperPayout         = keeperPayout_;
        payoutToSAFESize     = payoutToSAFESize_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        safeEngine           = SAFEEngineLike(collateralJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        collateralToken      = ERC20Like(collateralJoin.collateral());

        require(address(safeEngine) != address(0), "GeneralTokenReserveSafeSaviour/null-safe-engine");
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;

        require(scaledLiquidationRatio > 0, "GeneralTokenReserveSafeSaviour/invalid-scaled-liq-ratio");
        require(both(defaultDesiredCollateralizationRatio_ > scaledLiquidationRatio, defaultDesiredCollateralizationRatio_ <= MAX_CRATIO), "GeneralTokenReserveSafeSaviour/invalid-default-desired-cratio");
        require(collateralJoin.decimals() == 18, "GeneralTokenReserveSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "GeneralTokenReserveSafeSaviour/join-disabled");

        defaultDesiredCollateralizationRatio = defaultDesiredCollateralizationRatio_;
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit collateralToken in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param collateralTokenAmount The amount of collateralToken to deposit
    */
    function deposit(uint256 safeID, uint256 collateralTokenAmount) external liquidationEngineApproved(address(this)) nonReentrant {
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
    */
    function withdraw(uint256 safeID, uint256 collateralTokenAmount) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(collateralTokenAmount > 0, "GeneralTokenReserveSafeSaviour/null-collateralToken-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(collateralTokenCover[safeHandler] >= collateralTokenAmount, "GeneralTokenReserveSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        collateralTokenCover[safeHandler] = sub(collateralTokenCover[safeHandler], collateralTokenAmount);
        collateralToken.transfer(msg.sender, collateralTokenAmount);

        emit Withdraw(msg.sender, safeID, safeHandler, collateralTokenAmount);
    }

    // --- Adjust Cover Preferences ---
    /*
    * @notice Sets the collateralization ratio that a SAFE should have after it's saved
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to set the desired CRatio for. This ID should be registered inside GebSafeManager
    * @param cRatio The collateralization ratio to set
    */
    function setDesiredCollateralizationRatio(uint256 safeID, uint256 cRatio) external controlsSAFE(msg.sender, safeID) {
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;
        address safeHandler = safeManager.safes(safeID);

        require(scaledLiquidationRatio > 0, "GeneralTokenReserveSafeSaviour/invalid-scaled-liq-ratio");
        require(scaledLiquidationRatio < cRatio, "GeneralTokenReserveSafeSaviour/invalid-desired-cratio");
        require(cRatio <= MAX_CRATIO, "GeneralTokenReserveSafeSaviour/exceeds-max-cratio");

        desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] = cRatio;

        emit SetDesiredCollateralizationRatio(msg.sender, safeID, safeHandler, cRatio);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by adding more collateralToken into it
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being saved
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

        // Check that the amount of collateral locked in the safe is bigger than the keeper's payout
        (uint256 safeLockedCollateral,) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeLockedCollateral >= mul(keeperPayout, payoutToSAFESize), "GeneralTokenReserveSafeSaviour/tiny-safe");

        // Compute and check the validity of the amount of collateralToken used to save the SAFE
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);
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
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);

        if (tokenAmountUsed == MAX_UINT) {
            return false;
        }

        return (collateralTokenCover[safeHandler] >= add(tokenAmountUsed, keeperPayout));
    }
    /*
    * @notice Calculate the amount of collateralToken used to save a SAFE and bring its CRatio to the desired level
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of collateralToken used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedcollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        // If the SAFE doesn't have debt or if the price feed is faulty, abort
        if (either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue))) {
            tokenAmountUsed = MAX_UINT;
            return tokenAmountUsed;
        }

        // Calculate the value of the debt equivalent to the value of the collateralToken that would need to be in the SAFE after it's saved
        uint256 targetCRatio = (desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] == 0) ?
          defaultDesiredCollateralizationRatio : desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler];
        uint256 scaledDownDebtValue = mul(add(mul(oracleRelayer.redemptionPrice(), safeDebt) / RAY, ONE), targetCRatio) / HUNDRED;

        // Compute the amount of collateralToken the SAFE needs to get to the desired CRatio
        uint256 collateralTokenAmountNeeded = mul(scaledDownDebtValue, WAD) / priceFeedValue;

        // If the amount of collateralToken needed is lower than the amount that's currently in the SAFE, return 0
        if (collateralTokenAmountNeeded <= depositedcollateralToken) {
          return 0;
        } else {
          // Otherwise return the delta
          return sub(collateralTokenAmountNeeded, depositedcollateralToken);
        }
    }
}
