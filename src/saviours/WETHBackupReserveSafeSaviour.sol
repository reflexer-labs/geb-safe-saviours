pragma solidity 0.6.7;

import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract WETHBackupReserveSafeSaviour is SafeMath, SafeSaviourLike {
    // --- Variables ---
    mapping(address => uint256) public wethCover;
    CollateralJoinLike          public collateralJoin;
    ERC20Like                   public weth;

    // --- Events ---
    event Deposit(address indexed caller, address indexed safeHandler, uint256 amount);
    event Withdraw(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 amount);
    event SetDesiredCollateralizationRatio(address indexed caller, uint256 indexed safeID, address indexed safeHandler, uint256 cRatio);

    constructor(
      address collateralJoin_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeEngine_,
      address safeManager_,
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
        weth                 = ERC20Like(collateralJoin.collateral());

        uint256 scaledLiquidationRatio = oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) / CRATIO_SCALE_DOWN;

        require(scaledLiquidationRatio > 0, "WETHBackupReserveSafeSaviour/invalid-scaled-liq-ratio");
        require(both(defaultDesiredCollateralizationRatio_ > scaledLiquidationRatio, defaultDesiredCollateralizationRatio_ <= MAX_CRATIO), "WETHBackupReserveSafeSaviour/invalid-default-desired-cratio");
        require(collateralJoin.decimals() == 18, "WETHBackupReserveSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "WETHBackupReserveSafeSaviour/join-disabled");

        defaultDesiredCollateralizationRatio = defaultDesiredCollateralizationRatio_;
    }

    // --- Adding/Withdrawing Cover ---
    function deposit(uint256 safeID, uint256 wethAmount) external liquidationEngineApproved(address(this)) {
        require(wethAmount > 0, "WETHBackupReserveSafeSaviour/null-weth-amount");

        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "WETHBackupReserveSafeSaviour/null-handler");

        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "WETHBackupReserveSafeSaviour/safe-does-not-have-debt");

        wethCover[safeHandler] = add(wethCover[safeHandler], wethAmount);
        require(weth.transferFrom(msg.sender, address(this), wethAmount), "WETHBackupReserveSafeSaviour/could-not-transfer-weth");

        emit Deposit(msg.sender, safeHandler, wethAmount);
    }
    function withdraw(uint256 safeID, uint256 wethAmount) external controlsHandler(msg.sender, safeID) {
        require(wethAmount > 0, "WETHBackupReserveSafeSaviour/null-weth-amount");

        address safeHandler = safeManager.safes(safeID);

        wethCover[safeHandler] = sub(wethCover[safeHandler], wethAmount);
        weth.transfer(msg.sender, wethAmount);
        emit Withdraw(msg.sender, safeID, safeHandler, wethAmount);
    }

    // --- Adjust Cover Preferences ---
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
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "WETHBackupReserveSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "WETHBackupReserveSafeSaviour/null-keeper-address");
        require(collateralType == collateralJoin.collateralType(), "WETHBackupReserveSafeSaviour/invalid-collateral-type");

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "WETHBackupReserveSafeSaviour/small-keeper-payout-value");

        (uint256 safeLockedCollateral,) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeLockedCollateral >= mul(keeperPayout, payoutToSAFESize), "WETHBackupReserveSafeSaviour/tiny-safe");

        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);
        require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "WETHBackupReserveSafeSaviour/invalid-tokens-used-to-save");
        require(wethCover[safeHandler] >= add(keeperPayout, tokenAmountUsed), "WETHBackupReserveSafeSaviour/not-enough-cover-deposited");

        // Update the remaining cover
        wethCover[safeHandler] = sub(wethCover[safeHandler], add(keeperPayout, tokenAmountUsed));

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

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(PriceFeedLike(ethFSM).priceSource()).getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return false;
        }

        return (minKeeperPayoutValue <= mul(keeperPayout, priceFeedValue) / WAD);
    }
    function canSave(address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(safeHandler);

        if (tokenAmountUsed == MAX_UINT) {
            return false;
        }

        return (wethCover[safeHandler] >= add(tokenAmountUsed, keeperPayout));
    }
    function tokenAmountUsedToSave(address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedWETH, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        if (either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue))) {
            tokenAmountUsed = MAX_UINT;
            return tokenAmountUsed;
        }

        uint256 targetCRatio = (desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler] == 0) ?
          defaultDesiredCollateralizationRatio : desiredCollateralizationRatios[collateralJoin.collateralType()][safeHandler];
        uint256 scaledDownDebtValue = mul(add(mul(oracleRelayer.redemptionPrice(), safeDebt) / RAY, ONE), targetCRatio) / HUNDRED;
        uint256 wethAmountNeeded = mul(scaledDownDebtValue, WAD) / priceFeedValue;

        if (wethAmountNeeded <= depositedWETH) {
          return 0;
        } else {
          return sub(wethAmountNeeded, depositedWETH);
        }
    }
}
