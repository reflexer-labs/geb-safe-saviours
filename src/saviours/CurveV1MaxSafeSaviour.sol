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

import "../interfaces/SafeSaviourLike.sol";
import "../interfaces/CurveV1PoolLike.sol";
import "../interfaces/ERC20Like.sol";

import "../math/SafeMath.sol";

contract CurveV1MaxSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "CurveV1MaxSafeSaviour/account-not-authorized");
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
          "CurveV1MaxSafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Structs ---
    struct Reserves {
        uint256 systemCoins;
        uint256 collateralCoins;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                                         public restrictUsage;

    // Array used to store amounts of tokens removed from Curve when a SAFE is saved
    uint256[]                                       public removedCoinLiquidity;
    // Default array of min tokens to withdraw
    uint256[]                                       public defaultMinTokensToWithdraw;
    // Array of tokens in the Curve pool
    address[]                                       public poolTokens;

    // Amount of LP tokens currently protecting each position
    mapping(address => uint256)                     public lpTokenCover;
    // Amount of tokens that weren't used to save SAFEs and Safe owners can now get back
    mapping(address => mapping(address => uint256)) public underlyingReserves;

    // Curve pool
    CurveV1PoolLike                                 public curvePool;
    // The ERC20 system coin
    ERC20Like                                       public systemCoin;
    // The system coin join contract
    CoinJoinLike                                    public coinJoin;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike                              public collateralJoin;
    // The Curve LP token
    ERC20Like                                       public lpToken;
    // Oracle providing the system coin price feed
    PriceFeedLike                                   public systemCoinOrcl;

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
      address token,
      uint256 tokenAmount,
      address dst
    );

    constructor(
        address coinJoin_,
        address collateralJoin_,
        address systemCoinOrcl_,
        address liquidationEngine_,
        address taxCollector_,
        address oracleRelayer_,
        address safeManager_,
        address saviourRegistry_,
        address curvePool_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "CurveV1MaxSafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "CurveV1MaxSafeSaviour/null-collateral-join");
        require(systemCoinOrcl_ != address(0), "CurveV1MaxSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "CurveV1MaxSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "CurveV1MaxSafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "CurveV1MaxSafeSaviour/null-tax-collector");
        require(safeManager_ != address(0), "CurveV1MaxSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "CurveV1MaxSafeSaviour/null-saviour-registry");
        require(curvePool_ != address(0), "CurveV1MaxSafeSaviour/null-curve-pool");
        require(minKeeperPayoutValue_ > 0, "CurveV1MaxSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        minKeeperPayoutValue = minKeeperPayoutValue_;

        coinJoin             = CoinJoinLike(coinJoin_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        taxCollector         = TaxCollectorLike(taxCollector_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoinOrcl       = PriceFeedLike(systemCoinOrcl_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        curvePool            = CurveV1PoolLike(curvePool_);
        lpToken              = ERC20Like(curvePool.lp_token());

        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(collateralJoin.contractEnabled() == 1, "CurveV1MaxSafeSaviour/join-disabled");
        require(curvePool.redemption_price_snap() != address(0), "CurveV1MaxSafeSaviour/null-curve-red-price-snap");
        require(address(lpToken) != address(0), "CurveV1MaxSafeSaviour/null-curve-lp-token");
        require(address(safeEngine) != address(0), "CurveV1MaxSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "CurveV1MaxSafeSaviour/null-sys-coin");
        require(!curvePool.is_killed(), "CurveV1MaxSafeSaviour/pool-killed");

        address[] memory coins = curvePool.coins();
        require(coins.length > 1, "CurveV1MaxSafeSaviour/no-pool-coins");

        for (uint i = 0; i < coins.length; i++) {
          defaultMinTokensToWithdraw.push(0);
          poolTokens.push(coins[i]);
        }

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("taxCollector", taxCollector_);
        emit ModifyParameters("systemCoinOrcl", systemCoinOrcl_);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
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
            require(val > 0, "CurveV1MaxSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "CurveV1MaxSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("CurveV1MaxSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "CurveV1MaxSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
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
        else revert("CurveV1MaxSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Transferring Reserves ---
    /*
    * @notice Get back multiple tokens that were withdrawn from Curve and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param tokens The addresses of the tokens being transferred
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address[] calldata tokens, address dst)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(tokens.length > 0, "CurveV1MaxSafeSaviour/no-tokens");
        address safeHandler = safeManager.safes(safeID);

        uint256 reserve;
        for (uint i = 0; i < tokens.length; i++) {
          reserve = underlyingReserves[safeHandler][tokens[i]];
          if (reserve == 0) continue;

          delete(underlyingReserves[safeHandler][tokens[i]]);
          ERC20Like(tokens[i]).transfer(dst, reserve);

          emit GetReserves(msg.sender, safeHandler, tokens[i], reserve, dst);
        }
    }
    /*
    * @notify Get back tokens that were withdrawn from Curve and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param token The address of the token being transferred
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address token, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        uint256 reserve     = underlyingReserves[safeHandler][token];

        require(reserve > 0, "CurveV1MaxSafeSaviour/no-reserves");
        delete(underlyingReserves[safeHandler][token]);

        ERC20Like(token).transfer(dst, reserve);

        emit GetReserves(msg.sender, safeHandler, token, reserve, dst);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit lpToken in the contract in order to provide cover for a specific SAFE managed by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param lpTokenAmount The amount of lpToken to deposit
    */
    function deposit(uint256 safeID, uint256 lpTokenAmount)
      external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        require(!curvePool.is_killed(), "CurveV1MaxSafeSaviour/pool-killed");
        require(lpTokenAmount > 0, "CurveV1MaxSafeSaviour/null-lp-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "CurveV1MaxSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(address(safeEngine)).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "CurveV1MaxSafeSaviour/safe-does-not-have-debt");

        // Update the lpToken balance used to cover the SAFE and transfer tokens to this contract
        lpTokenCover[safeHandler] = add(lpTokenCover[safeHandler], lpTokenAmount);
        require(lpToken.transferFrom(msg.sender, address(this), lpTokenAmount), "CurveV1MaxSafeSaviour/could-not-transfer-lp");

        emit Deposit(msg.sender, safeHandler, lpTokenAmount);
    }
    /*
    * @notice Withdraw lpToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside the SAFE Manager
    * @param lpTokenAmount The amount of lpToken to withdraw
    * @param dst The address that will receive the LP tokens
    */
    function withdraw(uint256 safeID, uint256 lpTokenAmount, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(lpTokenAmount > 0, "CurveV1MaxSafeSaviour/null-lp-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(lpTokenCover[safeHandler] >= lpTokenAmount, "CurveV1MaxSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        lpTokenCover[safeHandler] = sub(lpTokenCover[safeHandler], lpTokenAmount);
        lpToken.transfer(dst, lpTokenAmount);

        emit Withdraw(msg.sender, safeHandler, dst, lpTokenAmount);
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by withdrawing liquidity and repaying debt and/or adding more collateral
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of LP tokens that were used to withdraw liquidity as well as the amount of
    *         system coins sent to the keeper as their payment (this implementation always returns 0)
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "CurveV1MaxSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "CurveV1MaxSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Check that the SAFE has a non null amount of LP tokens covering it
        require(
          either(lpTokenCover[safeHandler] > 0, underlyingReserves[safeHandler][address(systemCoin)] > 0),
          "CurveV1MaxSafeSaviour/null-cover"
        );

        // Tax the collateral
        taxCollector.taxSingle(collateralType);

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Remove all liquidity from Curve
        uint256 totalCover = lpTokenCover[safeHandler];
        removeLiquidity(safeHandler);

        // Record tokens that are not system coins and put them in reserves
        uint256 sysCoinBalance = underlyingReserves[safeHandler][address(systemCoin)];

        for (uint i = 0; i < removedCoinLiquidity.length; i++) {
          if (both(poolTokens[i] != address(systemCoin), removedCoinLiquidity[i] > 0)) {
            underlyingReserves[safeHandler][poolTokens[i]] = add(
              underlyingReserves[safeHandler][poolTokens[i]], removedCoinLiquidity[i]
            );
          } else {
            sysCoinBalance = add(sysCoinBalance, removedCoinLiquidity[i]);
          }
        }

        // Get the amounts of tokens sent to the keeper as payment
        uint256 keeperSysCoins =
          getKeeperPayoutTokens(
            safeHandler,
            sysCoinBalance
          );

        // There must be tokens that go to the keeper
        require(keeperSysCoins > 0, "CurveV1MaxSafeSaviour/cannot-pay-keeper");

        // Get the amount of tokens used to top up the SAFE
        uint256 safeDebtRepaid =
          getTokensForSaving(
            safeHandler,
            sub(sysCoinBalance, keeperSysCoins)
          );

        // There must be tokens used to save the SAVE
        require(safeDebtRepaid > 0, "CurveV1MaxSafeSaviour/cannot-save-safe");

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance = sub(sysCoinBalance, add(safeDebtRepaid, keeperSysCoins));

        // Update system coin reserves
        if (sysCoinBalance > 0) {
          underlyingReserves[safeHandler][address(systemCoin)] = sysCoinBalance;
        }

        // Save the SAFE
        {
          // Approve the coin join contract to take system coins and repay debt
          systemCoin.approve(address(coinJoin), safeDebtRepaid);
          // Calculate the non adjusted system coin amount
          (uint256 accumulatedRate, ) = getAccumulatedRateAndLiquidationPrice(collateralType);
          uint256 nonAdjustedSystemCoinsToRepay = div(mul(safeDebtRepaid, RAY), accumulatedRate);

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

        // Check the SAFE is saved
        require(safeIsAfloat(collateralType, safeHandler), "CurveV1MaxSafeSaviour/safe-not-saved");

        // Pay keeper
        systemCoin.transfer(keeper, keeperSysCoins);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, totalCover);

        return (true, totalCover, 0);
    }

    // --- Internal Logic ---
    /**
     * @notice Remove all Curve liquidity protecting a specific SAFE and return the amounts of all returned tokens
     * @param safeHandler The handler of the SAFE for which we withdraw Curve liquidity
     */
    function removeLiquidity(address safeHandler) internal {
        // Wipe storage
        delete(removedCoinLiquidity);
        require(removedCoinLiquidity.length == 0, "CurveV1MaxSafeSaviour/cannot-wipe-storage");

        for (uint i = 0; i < poolTokens.length; i++) {
          removedCoinLiquidity.push(ERC20Like(poolTokens[i]).balanceOf(address(this)));
        }

        uint256 totalCover = lpTokenCover[safeHandler];
        delete(lpTokenCover[safeHandler]);

        lpToken.approve(address(curvePool), totalCover);
        curvePool.remove_liquidity(totalCover, defaultMinTokensToWithdraw);

        for (uint i = 0; i < poolTokens.length; i++) {
          removedCoinLiquidity[i] = sub(ERC20Like(poolTokens[i]).balanceOf(address(this)), removedCoinLiquidity[i]);
        }
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
    * @notify Returns whether a SAFE can be currently saved; in this implementation it always returns false
    * @param safeHandler The safe handler associated with the SAFE
    */
    function canSave(bytes32, address safeHandler) override external returns (bool) {
        return false;
    }
    /*
    * @notice Return the total amount of LP tokens used to save a specific SAFE
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of LP tokens used to save a SAFE
    */
    function tokenAmountUsedToSave(bytes32, address safeHandler) override public returns (uint256) {
        return lpTokenCover[safeHandler];
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
    * @notice Return the amount of system coins used to save a SAFE
    * @param safeHandler The handler/address of the targeted SAFE
    * @param coinsLeft System coins left to save the SAFE after paying the liquidation keeper
    */
    function getTokensForSaving(
      address safeHandler,
      uint256 coinsLeft
    ) public view returns (uint256) {
        if (coinsLeft == 0) {
            return 0;
        }

        // Get the default CRatio for the SAFE
        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(address(safeEngine)).safes(collateralJoin.collateralType(), safeHandler);
        if (safeDebt == 0) {
            return 0;
        }

        // See how many system coins can be used to save the SAFE
        uint256 usedSystemCoins;
        (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralJoin.collateralType());
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralJoin.collateralType());

        if (coinsLeft >= safeDebt) usedSystemCoins = safeDebt;
        else if (debtFloor < mul(safeDebt, accumulatedRate)) {
          usedSystemCoins = min(sub(mul(safeDebt, accumulatedRate), debtFloor) / RAY, coinsLeft);
        }

        if (usedSystemCoins == 0) return 0;

        // See if the SAFE can be saved
        bool safeSaved = (
          mul(depositedCollateralToken, liquidationPrice) >
          mul(sub(safeDebt, usedSystemCoins), accumulatedRate)
        );

        if (safeSaved) return usedSystemCoins;
        return 0;
    }
    /*
    * @notice Return the amount of system coins used to pay a keeper
    * @param safeHandler The handler/address of the targeted SAFE
    * @param sysCoinsFromLP System coins withdrawn from Uniswap
    */
    function getKeeperPayoutTokens(
      address safeHandler,
      uint256 sysCoinsFromLP
    ) public view returns (uint256) {
        if (sysCoinsFromLP == 0) return 0;

        // Get the system coin market price
        uint256 sysCoinMarketPrice = getSystemCoinMarketPrice();
        if (sysCoinMarketPrice == 0) {
            return 0;
        }

        // Check if the keeper can be paid only with system coins, otherwise return zero
        uint256 payoutInSystemCoins = div(mul(minKeeperPayoutValue, WAD), sysCoinMarketPrice);

        if (payoutInSystemCoins <= sysCoinsFromLP) {
          return payoutInSystemCoins;
        }

        return 0;
    }
    /*
    * @notify Returns whether a SAFE is afloat
    * @param safeHandler The handler of the SAFE to verify
    */
    function safeIsAfloat(bytes32 collateralType, address safeHandler) public view returns (bool) {
        (, uint256 accumulatedRate, , , , uint256 liquidationPrice) = safeEngine.collateralTypes(collateralType);
        (uint256 safeCollateral, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);

        return (
          mul(safeCollateral, liquidationPrice) > mul(safeDebt, accumulatedRate)
        );
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
