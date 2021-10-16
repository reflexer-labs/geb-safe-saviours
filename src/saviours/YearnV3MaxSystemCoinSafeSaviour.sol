// Copyright (C) 2021 James Connolly, Reflexer Labs, INC

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

pragma solidity >=0.6.7;

import "../interfaces/YVault3Like.sol";
import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract YearnV3MaxSystemCoinSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "YearnV3MaxSystemCoinSafeSaviour/account-not-authorized");
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
          "YearnV3MaxSystemCoinSafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                     public restrictUsage;
    // Default max loss used when saving a Safe
    uint256                     public defaultMaxLoss = 1; // 0.01%

    // Amount of collateral deposited to cover each SAFE
    mapping(bytes32 => mapping(address => uint256)) public yvTokenCover;

    // The yVault address
    YVault3Like                 public yVault;
    // The ERC20 system coin
    ERC20Like                   public systemCoin;
    // The system coin join contract
    CoinJoinLike                public coinJoin;
    // Oracle providing the system coin price feed
    PriceFeedLike               public systemCoinOrcl;
    // Contract that defines desired CRatios for each Safe after it is saved
    SaviourCRatioSetterLike     public cRatioSetter;

    uint256                     public constant MAX_LOSS = 10_000; // 10k basis points

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event AllowUser(address usr);
    event DisallowUser(address usr);
    event ModifyParameters(bytes32 indexed parameter, uint256 val);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event Deposit(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      uint256 yvTokenAmount
    );
    event Withdraw(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      address dst,
      uint256 systemCoinAmount,
      uint256 yvTokenAmount
    );

    constructor(
      address coinJoin_,
      address cRatioSetter_,
      address systemCoinOrcl_,
      address liquidationEngine_,
      address taxCollector_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      address yVault_,
      uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-coin-join");
        require(cRatioSetter_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-cratio-setter");
        require(systemCoinOrcl_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-tax-collector");
        require(safeManager_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-saviour-registry");
        require(yVault_ != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-y-vault");
        require(minKeeperPayoutValue_ > 0, "YearnV3MaxSystemCoinSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        minKeeperPayoutValue = minKeeperPayoutValue_;

        coinJoin             = CoinJoinLike(coinJoin_);
        cRatioSetter         = SaviourCRatioSetterLike(cRatioSetter_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        taxCollector         = TaxCollectorLike(taxCollector_);

        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoinOrcl       = PriceFeedLike(systemCoinOrcl_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        yVault               = YVault3Like(yVault_);

        systemCoinOrcl.read();
        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(address(safeEngine) != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
        emit ModifyParameters("taxCollector", taxCollector_);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("systemCoinOrcl", systemCoinOrcl_);
    }

    // --- Math ---
    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x <= y) ? x : y;
    }

    // --- Administration ---
    /**
     * @notice Modify an uint256 param
     * @param parameter The name of the parameter
     * @param val New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "minKeeperPayoutValue") {
            require(val > 0, "YearnV3MaxSystemCoinSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "YearnV3MaxSystemCoinSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else if (parameter == "defaultMaxLoss") {
            require(val <= MAX_LOSS, "YearnV3MaxSystemCoinSafeSaviour/exceeds-max-loss");
            defaultMaxLoss = val;
        }
        else revert("YearnV3MaxSystemCoinSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
            systemCoinOrcl.read();
            systemCoinOrcl.getResultWithValidity();
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "liquidationEngine") {
            liquidationEngine = LiquidationEngineLike(data);
        }
        else if (parameter == "taxCollector") {
            taxCollector = TaxCollectorLike(data);
        }
        else revert("YearnV3MaxSystemCoinSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit systemCoin in the contract and lend in the Yearn vault in order to provide cover for a
    *         specific SAFE controlled by the SAFE Manager
    * @param collateralType The collateral type used in the SAFE
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param systemCoinAmount The amount of systemCoin to deposit
    */
    function deposit(bytes32 collateralType, uint256 safeID, uint256 systemCoinAmount)
      external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        uint256 defaultCRatio = cRatioSetter.defaultDesiredCollateralizationRatios(collateralType);
        require(systemCoinAmount > 0, "YearnV3MaxSystemCoinSafeSaviour/null-system-coin-amount");
        require(defaultCRatio > 0, "YearnV3MaxSystemCoinSafeSaviour/collateral-not-set");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);
        require(safeDebt > 0, "YearnV3MaxSystemCoinSafeSaviour/safe-does-not-have-debt");

        // Deposit into Yearn
        systemCoin.transferFrom(msg.sender, address(this), systemCoinAmount);
        systemCoin.approve(address(yVault), systemCoinAmount);
        uint256 yvTokens = yVault.deposit(systemCoinAmount, address(this)); // use return value to save on math operations
        require(yvTokens > 0, "YearnV3MaxSystemCoinSafeSaviour/no-vault-tokens-returned");

        // Update the yvToken balance used to cover the SAFE
        yvTokenCover[collateralType][safeHandler] = add(yvTokenCover[collateralType][safeHandler], yvTokens);

        emit Deposit(msg.sender, collateralType, safeHandler, systemCoinAmount, yvTokens);
    }
    /*
    * @notice Withdraw system coins from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param yvTokenAmount The amount of yvTokens to burn
    * @param maxLoss The maximum acceptable loss to sustain on withdrawal.
    *                If a loss is specified, up to that amount of shares may be burnt to cover losses on withdrawal.
    * @param dst The address that will receive the withdrawn system coins
    */
    function withdraw(bytes32 collateralType, uint256 safeID, uint256 yvTokenAmount, uint256 maxLoss, address dst)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(yvTokenAmount > 0, "YearnV3MaxSystemCoinSafeSaviour/null-yvToken-amount");
        require(dst != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-dst");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(yvTokenCover[collateralType][safeHandler] >= yvTokenAmount, "YearnV3MaxSystemCoinSafeSaviour/withdraw-request-higher-than-balance");

        // Redeem system coins from Yearn and transfer them to the caller
        yvTokenCover[collateralType][safeHandler] = sub(yvTokenCover[collateralType][safeHandler], yvTokenAmount);

        uint256 withdrawnSysCoinAmount = yVault.withdraw(yvTokenAmount, dst, maxLoss); // use return value to save on math operations
        require(withdrawnSysCoinAmount > 0, "YearnV3MaxSystemCoinSafeSaviour/no-coins-withdrawn");

        emit Withdraw(
          msg.sender,
          collateralType,
          safeHandler,
          dst,
          withdrawnSysCoinAmount,
          yvTokenAmount
        );
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by repaying some of its debt
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for
    *               spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of system coin debt repaid as well as the amount of
    *         system coins sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override
      external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "YearnV3MaxSystemCoinSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "YearnV3MaxSystemCoinSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Tax the collateral
        taxCollector.taxSingle(collateralType);

        // Get how many system coins the keeper has to get
        uint256 systemCoinKeeperPayout = getKeeperPayoutTokens();
        require(both(systemCoinKeeperPayout != 0, systemCoinKeeperPayout != MAX_UINT), "YearnV3MaxSystemCoinSafeSaviour/invalid-keeper-payout");

        // Compute and check the validity of the amount of system coins used to save the SAFE
        uint256 vaultPricePerShare = yVault.pricePerShare();
        uint256 systemCoinsToRepay = getTokensForSaving(collateralType, safeHandler, vaultPricePerShare, systemCoinKeeperPayout);
        require(both(systemCoinsToRepay != MAX_UINT, systemCoinsToRepay != 0), "YearnV3MaxSystemCoinSafeSaviour/invalid-tokens-used-to-save");
        uint256 yvTokensForSave    = div(mul(systemCoinsToRepay, WAD), vaultPricePerShare);

        // Check that there are enough yvTokens to cover both the keeper's payout and the amount used to save the SAFE
        uint256 yvTokensToWithdraw = add(yvTokensForSave, div(mul(systemCoinKeeperPayout, WAD), vaultPricePerShare));
        require(
          yvTokenCover[collateralType][safeHandler] >= yvTokensToWithdraw,
          "YearnV3MaxSystemCoinSafeSaviour/not-enough-cover-deposited"
        );

        // Update the remaining cover
        yvTokenCover[collateralType][safeHandler] = sub(yvTokenCover[collateralType][safeHandler], yvTokensToWithdraw);

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Get system coins back from the Yearn vault
        uint256 withdrawnAmount = yVault.withdraw(yvTokensToWithdraw, address(this), defaultMaxLoss);
        require(withdrawnAmount > 0, "YearnV3MaxSystemCoinSafeSaviour/null-sys-coin-withdrawn");
        systemCoinKeeperPayout = sub(withdrawnAmount, systemCoinsToRepay);

        // Approve the coin join contract to take system coins and repay debt
        systemCoin.approve(address(coinJoin), 0);
        systemCoin.approve(address(coinJoin), systemCoinsToRepay);

        // Join system coins in the system and repay the SAFE's debt
        {
          coinJoin.join(address(this), systemCoinsToRepay);
          (uint256 accumulatedRate, ) = getAccumulatedRateAndLiquidationPrice(collateralType);
          uint256 nonAdjustedSystemCoinsToRepay = div(mul(systemCoinsToRepay, RAY), accumulatedRate);

          safeEngine.modifySAFECollateralization(
            collateralType,
            safeHandler,
            address(0),
            address(this),
            int256(0),
            -int256(nonAdjustedSystemCoinsToRepay)
          );
        }

        // Send the fee to the keeper
        systemCoin.transfer(keeper, systemCoinKeeperPayout);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, yvTokensForSave);

        return (true, yvTokensForSave, 0);
    }

    // --- Getters ---
    /*
    * @notify Must be implemented according to the interface although it always returns false
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        return false;
    }
    /*
    * @notify Must be implemented according to the interface although it always returns 0
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        return 0;
    }
    /*
    * @notify Returns whether a SAFE can be currently saved; in this implementation it always returns false
    */
    function canSave(bytes32, address) override external returns (bool) {
        return false;
    }
    /*
    * @notice Return the amount of system coins that should be paid to a keeper
    */
    function getKeeperPayoutTokens() public view returns (uint256) {
        uint256 sysCoinMarketPrice = getSystemCoinMarketPrice();

        if (sysCoinMarketPrice == 0) {
            return MAX_UINT;
        }

        return div(mul(minKeeperPayoutValue, WAD), sysCoinMarketPrice);
    }
    /*
    * @notice Calculate the amount of system coins used to save a SAFE. This implementation always returns 0
    */
    function tokenAmountUsedToSave(bytes32, address) override public returns (uint256) {
        return 0;
    }
    /*
    * @notice Return the amount of system coins used to save a SAFE
    * @param collateralType The SAFE's collateral type
    * @param safeHandler The handler/address of the targeted SAFE
    * @param pricePerShare Current Yearn vault price per share
    * @param systemCoinKeeperPayout Amount of system coins used to pay a keeper
    */
    function getTokensForSaving(
      bytes32 collateralType,
      address safeHandler,
      uint256 pricePerShare,
      uint256 systemCoinKeeperPayout
    ) public view returns (uint256) {
        if (systemCoinKeeperPayout == 0) {
            return 0;
        }

        uint256 coinsLeft     = div(mul(yvTokenCover[collateralType][safeHandler], pricePerShare), WAD);
        coinsLeft             = sub(coinsLeft, systemCoinKeeperPayout);

        // Get the default CRatio for the SAFE
        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(address(safeEngine)).safes(collateralType, safeHandler);
        if (safeDebt == 0) {
            return 0;
        }

        // See how many system coins can be used to save the SAFE
        uint256 usedSystemCoins;
        (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralType);
        if (coinsLeft >= safeDebt) usedSystemCoins = safeDebt;
        else if (debtFloor < safeDebt) {
          usedSystemCoins = min(sub(safeDebt, debtFloor), coinsLeft);
        }

        // See if the SAFE can be saved
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralType);
        bool safeSaved = (
          mul(depositedCollateralToken, liquidationPrice) <
          mul(sub(safeDebt, usedSystemCoins), accumulatedRate)
        );

        if (safeSaved) return div(mul(usedSystemCoins, WAD), pricePerShare);
        return 0;
    }
    /*
    * @notify Fetch the system coin's market price
    */
    function getSystemCoinMarketPrice() public view returns (uint256) {
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
    }
    /*
    * @notify Returns whether a target debt amount is below the debt floor of a specific collateral type
    * @param collateralType The collateral type whose floor we compare against
    * @param targetDebtAmount The target debt amount for a SAFE that has collateralType collateral in it
    */
    function debtBelowFloor(bytes32 collateralType, uint256 targetDebtAmount) public view returns (bool) {
        (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralType);
        return (mul(targetDebtAmount, RAY) < debtFloor);
    }
    /*
    * @notify Get the accumulated interest rate for a specific collateral type as well as its current liquidation price
    * @param The collateral type for which to retrieve the rate and the price
    */
    function getAccumulatedRateAndLiquidationPrice(bytes32 collateralType)
      public view returns (uint256 accumulatedRate, uint256 liquidationPrice) {
        (, accumulatedRate, , , , liquidationPrice) = safeEngine.collateralTypes(collateralType);
    }
}
