pragma solidity 0.6.7;

import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract WETHBackupReserveSafeSaviour is SafeMath, SafeSaviourLike {
    // --- Variables ---
    // Amount of WETH deposited to cover each SAFE
    mapping(address => uint256) public wethCover;
    // The WETH join contract for adding collateral in the system
    CollateralJoinLike          public collateralJoin;
    // The WETH token
    ERC20Like                   public weth;

    // --- Events ---
    event Deposit(address indexed caller, address indexed safeHandler, uint256 amount);
    event Withdraw(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 amount);
    event SetDesiredCollateralizationRatio(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 cRatio);
    event SaveSAFE(address keeper, bytes32 indexed collateralType, address indexed safeHandler, uint256 collateralAdded);

    constructor(
      address collateralJoin_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeEngine_,
      address safeManager_,
      address saviourRegistry_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_,
      uint256 payoutToSAFESize_,
      uint256 defaultDesiredCollateralizationRatio_
    ) public {
        require(collateralJoin_ != address(0), "WETHBackupReserveSafeSaviour/null-collateral-join");
        require(liquidationEngine_ != address(0), "WETHBackupReserveSafeSaviour/null-liquidation-engine");
        require(oracleRelayer_ != address(0), "WETHBackupReserveSafeSaviour/null-oracle-relayer");
        require(safeEngine_ != address(0), "WETHBackupReserveSafeSaviour/null-safe-engine");
        require(safeManager_ != address(0), "WETHBackupReserveSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "WETHBackupReserveSafeSaviour/null-saviour-registry");
        require(keeperPayout_ > 0, "WETHBackupReserveSafeSaviour/invalid-keeper-payout");
        require(defaultDesiredCollateralizationRatio_ > 0, "WETHBackupReserveSafeSaviour/null-default-cratio");
        require(payoutToSAFESize_ > 1, "WETHBackupReserveSafeSaviour/invalid-payout-to-safe-size");
        require(minKeeperPayoutValue_ > 0, "WETHBackupReserveSafeSaviour/invalid-min-payout-value");

        keeperPayout         = keeperPayout_;
        payoutToSAFESize     = payoutToSAFESize_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        safeEngine           = SAFEEngineLike(safeEngine_);
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        weth                 = ERC20Like(collateralJoin.collateral());

        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;

        require(scaledLiquidationRatio > 0, "WETHBackupReserveSafeSaviour/invalid-scaled-liq-ratio");
        require(both(defaultDesiredCollateralizationRatio_ > scaledLiquidationRatio, defaultDesiredCollateralizationRatio_ <= MAX_CRATIO), "WETHBackupReserveSafeSaviour/invalid-default-desired-cratio");
        require(collateralJoin.decimals() == 18, "WETHBackupReserveSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "WETHBackupReserveSafeSaviour/join-disabled");

        defaultDesiredCollateralizationRatio = defaultDesiredCollateralizationRatio_;
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit WETH in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param wethAmount The amount of WETH to deposit
    */
    function deposit(uint256 safeID, uint256 wethAmount) external liquidationEngineApproved(address(this)) {
        require(wethAmount > 0, "WETHBackupReserveSafeSaviour/null-weth-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "WETHBackupReserveSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "WETHBackupReserveSafeSaviour/safe-does-not-have-debt");

        // Update the WETH balance used to cover the SAFE and transfer WETH to this contract
        wethCover[safeHandler] = add(wethCover[safeHandler], wethAmount);
        require(weth.transferFrom(msg.sender, address(this), wethAmount), "WETHBackupReserveSafeSaviour/could-not-transfer-weth");

        emit Deposit(msg.sender, safeHandler, wethAmount);
    }
    /*
    * @notice Withdraw WETH from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param wethAmount The amount of WETH to withdraw
    */
    function withdraw(uint256 safeID, uint256 wethAmount) external controlsHandler(msg.sender, safeID) {
        require(wethAmount > 0, "WETHBackupReserveSafeSaviour/null-weth-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(wethCover[safeHandler] >= wethAmount, "WETHBackupReserveSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer WETH to the caller
        wethCover[safeHandler] = sub(wethCover[safeHandler], wethAmount);
        weth.transfer(msg.sender, wethAmount);

        emit Withdraw(msg.sender, safeID, safeHandler, wethAmount);
    }

    // --- Adjust Cover Preferences ---
    /*
    * @notice Sets the collateralization ratio that a SAFE should have after it's saved
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to set the desired CRatio for. This ID should be registered inside GebSafeManager
    * @param cRatio The collateralization ratio to set
    */
    function setDesiredCollateralizationRatio(uint256 safeID, uint256 cRatio) external controlsHandler(msg.sender, safeID) {
        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;
        address safeHandler = safeManager.safes(safeID);

        require(scaledLiquidationRatio > 0, "WETHBackupReserveSafeSaviour/invalid-scaled-liq-ratio");
        require(scaledLiquidationRatio < cRatio, "WETHBackupReserveSafeSaviour/invalid-desired-cratio");
        require(cRatio <= MAX_CRATIO, "WETHBackupReserveSafeSaviour/exceeds-max-cratio");

        desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] = cRatio;

        emit SetDesiredCollateralizationRatio(msg.sender, safeID, safeHandler, cRatio);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by adding more WETH into it
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being saved
    * @return Whether the SAFE has been saved, the amount of WETH added in the SAFE as well as the amount of WETH sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "WETHBackupReserveSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "WETHBackupReserveSafeSaviour/null-keeper-address");
        require(collateralType == collateralJoin.collateralType(), "WETHBackupReserveSafeSaviour/invalid-collateral-type");

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "WETHBackupReserveSafeSaviour/small-keeper-payout-value");

        // Check that the amount of collateral locked in the safe is bigger than the keeper's payout
        (uint256 safeLockedCollateral,) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeLockedCollateral >= mul(keeperPayout, payoutToSAFESize), "WETHBackupReserveSafeSaviour/tiny-safe");

        // Compute and check the validity of the amount of WETH used to save the SAFE
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);
        require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "WETHBackupReserveSafeSaviour/invalid-tokens-used-to-save");

        // Check that there's enough WETH added as to cover both the keeper's payout and the amount used to save the SAFE
        require(wethCover[safeHandler] >= add(keeperPayout, tokenAmountUsed), "WETHBackupReserveSafeSaviour/not-enough-cover-deposited");

        // Update the remaining cover
        wethCover[safeHandler] = sub(wethCover[safeHandler], add(keeperPayout, tokenAmountUsed));

        // Mark the SAFE in the registry as just being saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Approve WETH to the collateral join contract
        weth.approve(address(collateralJoin), 0);
        weth.approve(address(collateralJoin), tokenAmountUsed);

        // Join WETH in the system and add it in the saved SAFE
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
        weth.transfer(keeper, keeperPayout);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, tokenAmountUsed);

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    /*
    * @notice Compute whether the value of keeperPayout WETH is higher than or equal to minKeeperPayoutValue
    * @dev Used to determine whether it's worth it for the keeper to save the SAFE in exchange for keeperPayout WETH
    * @return A bool representing whether the value of keeperPayout WETH is >= minKeeperPayoutValue
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
    * @notice Determine whether a SAFE can be saved with the current amount of WETH deposited as cover for it
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);

        if (tokenAmountUsed == MAX_UINT) {
            return false;
        }

        return (wethCover[safeHandler] >= add(tokenAmountUsed, keeperPayout));
    }
    /*
    * @notice Calculate the amount of WETH used to save a SAFE and bring its CRatio to the desired level
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of WETH used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedWETH, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        // If the SAFE doesn't have debt or if the price feed is faulty, abort
        if (either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue))) {
            tokenAmountUsed = MAX_UINT;
            return tokenAmountUsed;
        }

        // Calculate the value of the debt equivalent to the value of the WETH that would need to be in the SAFE after it's saved
        uint256 targetCRatio = (desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] == 0) ?
          defaultDesiredCollateralizationRatio : desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler];
        uint256 scaledDownDebtValue = mul(add(mul(oracleRelayer.redemptionPrice(), safeDebt) / RAY, ONE), targetCRatio) / HUNDRED;

        // Compute the amount of WETH the SAFE needs to get to the desired CRatio
        uint256 wethAmountNeeded = mul(scaledDownDebtValue, WAD) / priceFeedValue;

        // If the amount of WETH needed is lower than the amount that's currently in the SAFE, return 0
        if (wethAmountNeeded <= depositedWETH) {
          return 0;
        } else {
          // Otherwise return the delta
          return sub(wethAmountNeeded, depositedWETH);
        }
    }
}
