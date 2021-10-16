// Copyright (C) 2021 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

pragma solidity >=0.6.7;

import "../interfaces/UniswapLiquidityManagerLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";
import "../math/Math.sol";

contract NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour is Math, SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/account-not-authorized");
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
          "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                        public restrictUsage;
    // Whether the system coin is token0 in the Uniswap pool or not
    bool                           public isSystemCoinToken0;

    // Amount of LP tokens currently protecting each position
    mapping(address => uint256)    public lpTokenCover;
    // Amount of system coin tokens that Safe owners can get back
    mapping(address => uint256)    public underlyingReserves;
    // cRatio threshold for each Safe, below which anyone can call saveSAFE (safeHandler, threshold)
    mapping(address => uint)       public cRatioThresholds;

    // Liquidity manager contract for Uniswap v2/v3
    UniswapLiquidityManagerLike    public liquidityManager;
    // The ERC20 system coin
    ERC20Like                      public systemCoin;
    // The system coin join contract
    CoinJoinLike                   public coinJoin;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike             public collateralJoin;
    // The LP token
    ERC20Like                      public lpToken;
    // The collateral token
    ERC20Like                      public collateralToken;
    // Oracle providing the system coin price feed
    PriceFeedLike                  public systemCoinOrcl;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event AllowUser(address usr);
    event DisallowUser(address usr);
    event ModifyParameters(bytes32 indexed parameter, uint256 val);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event Deposit(
      address indexed caller,
      address indexed safeHandler,
      uint256 lpTokenAmount
    );
    event Withdraw(
      address indexed caller,
      address indexed safeHandler,
      address dst,
      uint256 lpTokenAmount
    );
    event GetReserves(
      address indexed caller,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      address dst
    );

    constructor(
        bool isSystemCoinToken0_,
        address coinJoin_,
        address collateralJoin_,
        address systemCoinOrcl_,
        address liquidationEngine_,
        address taxCollector_,
        address oracleRelayer_,
        address safeManager_,
        address liquidityManager_,
        address lpToken_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-collateral-join");
        require(systemCoinOrcl_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-tax-collector");
        require(safeManager_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-safe-manager");
        require(liquidityManager_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-liq-manager");
        require(lpToken_ != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-lp-token");
        require(minKeeperPayoutValue_ > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        isSystemCoinToken0    = isSystemCoinToken0_;
        minKeeperPayoutValue  = minKeeperPayoutValue_;

        coinJoin              = CoinJoinLike(coinJoin_);
        collateralJoin        = CollateralJoinLike(collateralJoin_);
        liquidationEngine     = LiquidationEngineLike(liquidationEngine_);
        taxCollector          = TaxCollectorLike(taxCollector_);
        oracleRelayer         = OracleRelayerLike(oracleRelayer_);
        systemCoinOrcl        = PriceFeedLike(systemCoinOrcl_);
        systemCoin            = ERC20Like(coinJoin.systemCoin());
        safeEngine            = SAFEEngineLike(coinJoin.safeEngine());
        safeManager           = GebSafeManagerLike(safeManager_);
        liquidityManager      = UniswapLiquidityManagerLike(liquidityManager_);
        lpToken               = ERC20Like(lpToken_);
        collateralToken       = ERC20Like(collateralJoin.collateral());

        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(collateralJoin.contractEnabled() == 1, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/join-disabled");
        require(address(collateralToken) != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-col-token");
        require(address(safeEngine) != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("taxCollector", taxCollector_);
        emit ModifyParameters("systemCoinOrcl", systemCoinOrcl_);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
        emit ModifyParameters("liquidityManager", liquidityManager_);
    }

    // --- Administration ---
    /**
     * @notice Modify an uint256 param
     * @param parameter The name of the parameter
     * @param val New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "minKeeperPayoutValue") {
            require(val > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
            systemCoinOrcl.getResultWithValidity();
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "liquidityManager") {
            liquidityManager = UniswapLiquidityManagerLike(data);
        }
        else if (parameter == "liquidationEngine") {
            liquidationEngine = LiquidationEngineLike(data);
        }
        else if (parameter == "taxCollector") {
            taxCollector = TaxCollectorLike(data);
        }
        else revert("NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Setting cRatio Threshold ---
    /*
    * @notice Set cRatio threshold
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param safeID The ID of the SAFE to set the threshold for. This ID should be registered inside the SAFE Manager
    * @param cRatioThreshold The threshold below which the SAFE can be saved
    */
    function setCRatioThreshold(uint256 safeID, uint256 cRatioThreshold) external controlsSAFE(msg.sender, safeID) {
        address safeHandler = safeManager.safes(safeID);
        cRatioThresholds[safeHandler] = cRatioThreshold;
    }
    // --- Transferring Reserves ---
    /*
    * @notify Get back system coins that were withdrawn from Uniswap and not used to save a specific SAFE
    * @param safeID The ID of the Safe that was previously saved and has leftover system coins that can be withdrawn
    * @param dst The address that will receive system coins
    */
    function getReserves(uint256 safeID, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        uint256 systemCoins = underlyingReserves[safeHandler];

        require(systemCoins > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/no-reserves");
        underlyingReserves[safeHandler] = 0;

        systemCoin.transfer(dst, systemCoins);

        emit GetReserves(msg.sender, safeHandler, systemCoins, dst);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit lpTokenAmount in the contract in order to provide cover for a specific SAFE managed by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param lpTokenAmount The amount of LP tokens to deposit
    * @param threshold cRatio threshold
    */
    function deposit(uint256 safeID, uint256 lpTokenAmount) external isAllowed() nonReentrant {
        require(lpTokenAmount > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-lp-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/safe-does-not-have-debt");

        // Update the lpToken balance used to cover the SAFE and transfer tokens to this contract
        lpTokenCover[safeHandler] = add(lpTokenCover[safeHandler], lpTokenAmount);
        require(lpToken.transferFrom(msg.sender, address(this), lpTokenAmount), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/could-not-transfer-lp");

        emit Deposit(msg.sender, safeHandler, lpTokenAmount);
    }
    /*
    * @notice Withdraw lpTokenAmount from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside the SAFE Manager
    * @param lpTokenAmount The amount of lpToken to withdraw
    * @param dst The address that will receive the LP tokens
    */
    function withdraw(uint256 safeID, uint256 lpTokenAmount, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(lpTokenAmount > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-lp-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(lpTokenCover[safeHandler] >= lpTokenAmount, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        lpTokenCover[safeHandler] = sub(lpTokenCover[safeHandler], lpTokenAmount);
        lpToken.transfer(dst, lpTokenAmount);

        emit Withdraw(msg.sender, safeHandler, dst, lpTokenAmount);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by withdrawing liquidity and repaying debt and/or adding more collateral
    * @param keeper The keeper that should be rewarded for spending gas to save the SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of LP tokens that were used to withdraw liquidity as well as the amount of
    *         system coins sent to the keeper as their payment (this implementation always returns 0)
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external nonReentrant returns (bool, uint256, uint256) {
        require(keeper != address(0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-keeper-address");

        // Check that this is handling the correct collateral
        require(collateralType == collateralJoin.collateralType(), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/invalid-collateral-type");

        // Check that the SAFE has a non null amount of LP tokens covering it
        require(lpTokenCover[safeHandler] > 0, "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/null-cover");

        // Tax the collateral
        taxCollector.taxSingle(collateralType);

        // calls allowed if safe cRatio is lower than user defined cRatio
        require(getSafeCRatio(safeHandler) <= mul(cRatioThresholds[safeHandler], RAY / 100),
            "NativeUnderlyingUniswapV2SafeSaviour/safe-above-threshold");

        // Store cover amount in local var
        uint256 totalCover = lpTokenCover[safeHandler];
        delete(lpTokenCover[safeHandler]);

        // Withdraw all liquidity
        uint256 sysCoinBalance        = systemCoin.balanceOf(address(this));

        lpToken.approve(address(liquidityManager), totalCover);
        liquidityManager.removeLiquidity(totalCover, 0, 0, address(this));

        // Check after removing liquidity
        require(
          systemCoin.balanceOf(address(this)) > sysCoinBalance,
          "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/faulty-remove-liquidity"
        );

        // Compute how many coins were withdrawn as well as the amount of ETH that's in this contract
        sysCoinBalance                = sub(systemCoin.balanceOf(address(this)), sysCoinBalance);
        uint256 collateralCoinBalance = collateralToken.balanceOf(address(this));

        // Get the amounts of tokens sent to the keeper as payment
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(safeHandler, oracleRelayer.redemptionPrice(), sysCoinBalance, collateralCoinBalance);

        // There must be tokens that go to the keeper
        require(either(keeperSysCoins > 0, keeperCollateralCoins > 0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/cannot-pay-keeper");

        // Compute how many coins remain after paying the keeper
        sysCoinBalance        = sub(sysCoinBalance, keeperSysCoins);
        collateralCoinBalance = sub(collateralCoinBalance, keeperCollateralCoins);

        // There must be tokens that are used to save the SAFE
        require(either(sysCoinBalance > 0, collateralCoinBalance > 0), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/cannot-save-safe");

        // Get the amount of system coins used to repay debt
        uint256 safeDebtRepaid = getTokensForSaving(safeHandler, sysCoinBalance);

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance         = sub(sysCoinBalance, safeDebtRepaid);

        // Update reserves
        if (sysCoinBalance > 0) {
          underlyingReserves[safeHandler] = add(
            underlyingReserves[safeHandler], sysCoinBalance
          );
        }

        // Save the SAFE
        if (safeDebtRepaid > 0) {
          // Approve the coin join contract to take system coins and repay debt
          systemCoin.approve(address(coinJoin), safeDebtRepaid);
          // Calculate the non adjusted system coin amount
          uint256 nonAdjustedSystemCoinsToRepay = div(mul(safeDebtRepaid, RAY), getAccumulatedRate(collateralType));

          // Join system coins in the system and repay the SAFE's debt
          coinJoin.join(address(this), safeDebtRepaid);
          safeEngine.modifySAFECollateralization(
            collateralType,
            safeHandler,
            address(0),
            address(this),
            int256(0),
            -int256(nonAdjustedSystemCoinsToRepay)
          );
        }

        if (collateralCoinBalance > 0) {
          // Approve collateralToken to the collateral join contract
          collateralToken.approve(address(collateralJoin), collateralCoinBalance);

          // Join collateralToken in the system and add it in the saved SAFE
          collateralJoin.join(address(this), collateralCoinBalance);
          safeEngine.modifySAFECollateralization(
            collateralType,
            safeHandler,
            address(this),
            address(0),
            int256(collateralCoinBalance),
            int256(0)
          );
        }

        // Check that the current cRatio is above the liquidation threshold
        require(safeIsAfloat(safeHandler), "NativeUnderlyingTargetUniswapV2CustomCRatioSafeSaviour/safe-not-saved");

        // Pay keeper
        if (keeperSysCoins > 0) {
          systemCoin.transfer(keeper, keeperSysCoins);
        }

        if (keeperCollateralCoins > 0) {
          collateralToken.transfer(keeper, keeperCollateralCoins);
        }

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, totalCover);

        return (true, totalCover, 0);
    }

    // --- Getters ---
    /*
    * @notify Must be implemented according to the interface although it always returns 0
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        return 0;
    }
    /*
    * @notify Must be implemented according to the interface although it always returns false
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        return false;
    }
    /*
    * @notice Determine whether a SAFE can be saved with the current amount of lpTokenCover deposited as cover for it
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(bytes32, address safeHandler) override external returns (bool) {
        // Fetch the redemption price first
        uint256 redemptionPrice = oracleRelayer.redemptionPrice();

        // Fetch the amount of tokens used to save the SAFE
        (uint256 systemCoinAmount, uint256 collateralAmount) =
          getLPUnderlying(safeHandler);

        // Get the amounts of tokens sent to the keeper as payment
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(safeHandler, oracleRelayer.redemptionPrice(), systemCoinAmount, collateralAmount);

        // Compute how many coins remain after paying the keeper
        systemCoinAmount = sub(systemCoinAmount, keeperSysCoins);
        collateralAmount = sub(collateralAmount, keeperCollateralCoins);

        // There must be tokens that can be used to save the SAFE
        if (both(systemCoinAmount == 0, collateralAmount == 0)) {
            return false;
        }

        // Get the amount of system coins used to repay debt
        uint256 safeDebtRepaid = getTokensForSaving(safeHandler, systemCoinAmount);
        if (safeDebtRepaid > systemCoinAmount) return false;

        // If resulting debt is below the floor or if the SAFE can't be saved, return false
        {
          (, uint256 accumulatedRate, , , uint256 debtFloor, uint256 liquidationPrice) =
            safeEngine.collateralTypes(collateralJoin.collateralType());
          (uint256 safeCollateral, uint256 safeDebt) = safeEngine.safes(collateralJoin.collateralType(), safeHandler);

          uint256 remainingDebt = sub(safeDebt, safeDebtRepaid);

          if (either(
            both(mul(remainingDebt, accumulatedRate) < debtFloor, remainingDebt != 0),
            mul(add(safeCollateral, collateralAmount), liquidationPrice) < mul(remainingDebt, accumulatedRate)
          )) {
            return false;
          }
        }

        // If there are some tokens used to used to repay the keeper, return true
        if (either(keeperSysCoins > 0, keeperCollateralCoins > 0)) {
          return true;
        }

        return false;
    }
    /*
    * @notice Return the total amount of LP tokens covering a specific SAFE
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The total LP token cover for a specific SAFE
    */
    function tokenAmountUsedToSave(bytes32, address safeHandler) override public returns (uint256) {
        return lpTokenCover[safeHandler];
    }
    /*
    * @notify Fetch the collateral's price
    */
    function getCollateralPrice() public view returns (uint256) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        if (ethFSM == address(0)) return 0;

        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
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
    * @notify Get the current collateralization ratio of a SAFE
    * @param safeHandler The handler/address of the SAFE whose collateralization ratio is retrieved
    */
    function getSafeCRatio(address safeHandler) public view returns (uint256) {
        bytes32 collateralType = collateralJoin.collateralType();
        (, uint256 accumulatedRate, uint256 safetyPrice, , , ) = safeEngine.collateralTypes(collateralType);
        (,, uint256 liquidationCRatio) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        (uint256 collateralBalance, uint256 debtBalance) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);

        return div(mul(collateralBalance, mul(safetyPrice, liquidationCRatio)), mul(debtBalance, accumulatedRate));
    }
    /*
    * @notify Return the amount of system coins and collateral tokens retrieved from the LP position covering a specific SAFE
    * @param safeHandler The handler/address of the targeted SAFE
    */
    function getLPUnderlying(address safeHandler) public view returns (uint256, uint256) {
        uint256 coverAmount = lpTokenCover[safeHandler];

        if (coverAmount == 0) return (0, 0);

        (uint256 sysCoinsFromLP, uint256 collateralFromLP) = (isSystemCoinToken0) ?
          (liquidityManager.getToken0FromLiquidity(coverAmount), liquidityManager.getToken1FromLiquidity(coverAmount)) :
          (liquidityManager.getToken1FromLiquidity(coverAmount), liquidityManager.getToken0FromLiquidity(coverAmount));

        return (sysCoinsFromLP, collateralFromLP);
    }
    /*
    * @notice Return the amount of system coins used to save a SAFE
    * @param safeHandler The handler/address of the targeted SAFE
    * @param maxSystemCoins Max amount of system coins that can be used to save the SAFE
    */
    function getTokensForSaving(address safeHandler, uint256 maxSystemCoins)
      public view returns (uint256) {
        if (maxSystemCoins == 0) return 0;

        bytes32 collateralType = collateralJoin.collateralType();

        // Get the SAFE debt
        (, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);

        if (safeDebt <= maxSystemCoins) {
          return safeDebt;
        }

        (, uint256 accumulatedRate, , , uint debtFloor, ) = safeEngine.collateralTypes(collateralType);
        uint256 adjustedDebt = mul(accumulatedRate, safeDebt);

        if (debtFloor >= adjustedDebt) {
          return 0;
        }

        uint256 debtToRepay = sub(adjustedDebt, debtFloor) / RAY;

        return min(maxSystemCoins, debtToRepay);
    }
    /*
    * @notice Return the amount of system coins and/or collateral tokens used to pay a keeper
    * @param safeHandler The handler/address of the targeted SAFE
    * @param redemptionPrice The system coin redemption price used in calculations
    * @param sysCoinAmount Amount of system coin available
    * @param collateralAmount The amount of collateral tokens that are available
    */
    function getKeeperPayoutTokens(address safeHandler, uint256 redemptionPrice, uint256 sysCoinAmount, uint256 collateralAmount)
      public view returns (uint256, uint256) {
        // Get the system coin and collateral market prices
        uint256 collateralPrice    = getCollateralPrice();
        uint256 sysCoinMarketPrice = getSystemCoinMarketPrice();
        if (either(collateralPrice == 0, sysCoinMarketPrice == 0)) {
            return (0, 0);
        }

        // Check if the keeper can get system coins and if yes, compute how many
        uint256 keeperSysCoins;
        uint256 payoutInSystemCoins  = div(mul(minKeeperPayoutValue, WAD), sysCoinMarketPrice);

        if (payoutInSystemCoins <= sysCoinAmount) {
            return (payoutInSystemCoins, 0);
        } else {
            keeperSysCoins = sysCoinAmount;
        }

        // Calculate how much collateral the keeper will get
        uint256 remainingKeeperPayoutValue = sub(minKeeperPayoutValue, mul(keeperSysCoins, sysCoinMarketPrice) / WAD);
        uint256 collateralTokenNeeded      = div(mul(remainingKeeperPayoutValue, WAD), collateralPrice);

        // If there are enough collateral tokens retreived from LP in order to pay the keeper, return the token amounts
        if (collateralTokenNeeded <= collateralAmount) {
          return (keeperSysCoins, collateralTokenNeeded);
        } else {
          // Otherwise, return zeroes
          return (0, 0);
        }
    }
    /*
    * @notify Returns whether a SAFE is afloat
    * @param safeHandler The handler of the SAFE to verify
    */
    function safeIsAfloat(address safeHandler) public view returns (bool) {
        (, uint256 accumulatedRate, , , , uint256 liquidationPrice) = safeEngine.collateralTypes(collateralJoin.collateralType());
        (uint256 safeCollateral, uint256 safeDebt) = safeEngine.safes(collateralJoin.collateralType(), safeHandler);

        return (
          mul(safeCollateral, liquidationPrice) > mul(safeDebt, accumulatedRate)
        );
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
