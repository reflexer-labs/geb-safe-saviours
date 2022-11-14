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
import "../interfaces/CurveV2PoolLike.sol";
import "../interfaces/ERC20Like.sol";

import "../math/SafeMath.sol";

contract CurveV2MaxSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "CurveV2MaxSafeSaviour/account-not-authorized");
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
          "CurveV2MaxSafeSaviour/account-not-allowed"
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
    // Number of tokens in the Curve pool
    uint256                                         public immutable poolTokensCount;
    // Array of tokens in the Curve pool
    mapping(uint256 => address)                     public poolTokens;

    // Amount of LP tokens currently protecting each position
    mapping(bytes32 => mapping(address => uint256)) public lpTokenCover;
    // Amount of tokens that weren't used to save SAFEs and Safe owners can now get back
    mapping(address => mapping(address => uint256)) public underlyingReserves;

    // Curve pool
    CurveV2PoolLike                                 public curvePool;
    // The ERC20 system coin
    ERC20Like                                       public systemCoin;
    // The system coin join contract
    CoinJoinLike                                    public coinJoin;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike                              public collateralJoin;
    // The Curve LP token
    ERC20Like                                       public lpToken;
    // The collateral token
    ERC20Like                                       public collateralToken;
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
      bytes32 collateralType,
      address indexed safeHandler,
      uint256 lpTokenAmount
    );
    event Withdraw(
      address indexed caller,
      bytes32 collateralType,
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
        require(coinJoin_ != address(0), "CurveV2MaxSafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "CurveV2MaxSafeSaviour/null-collateral-join");
        require(systemCoinOrcl_ != address(0), "CurveV2MaxSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "CurveV2MaxSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "CurveV2MaxSafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "CurveV2MaxSafeSaviour/null-tax-collector");
        require(safeManager_ != address(0), "CurveV2MaxSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "CurveV2MaxSafeSaviour/null-saviour-registry");
        require(curvePool_ != address(0), "CurveV2MaxSafeSaviour/null-curve-pool");
        require(minKeeperPayoutValue_ > 0, "CurveV2MaxSafeSaviour/invalid-min-payout-value");

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
        curvePool            = CurveV2PoolLike(curvePool_);
        lpToken              = ERC20Like(curvePool.token());
        collateralToken      = ERC20Like(collateralJoin.collateral());

        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(address(lpToken) != address(0), "CurveV2MaxSafeSaviour/null-curve-lp-token");
        require(collateralJoin.contractEnabled() == 1, "CurveV2MaxSafeSaviour/join-disabled");
        require(address(collateralToken) != address(0), "CurveV2MaxSafeSaviour/null-col-token");
        require(address(safeEngine) != address(0), "CurveV2MaxSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "CurveV2MaxSafeSaviour/null-sys-coin");

        uint256 i;
        for (; i != 4; ++i) {
          try curvePool.coins(i) returns (address coin) {
            poolTokens[i] = coin;
          } catch {
            break;
          }
        }
        poolTokensCount = i;

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
            require(val > 0, "CurveV2MaxSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "CurveV2MaxSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("CurveV2MaxSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "CurveV2MaxSafeSaviour/null-data");

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
        else revert("CurveV2MaxSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Transferring Reserves ---
    /**
    * @notice Get back multiple tokens that were withdrawn from Curve and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param tokens The addresses of the tokens being transferred
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address[] calldata tokens, address dst)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(tokens.length > 0, "CurveV2MaxSafeSaviour/no-tokens");
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
    /**
    * @notice Get back tokens that were withdrawn from Curve and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param token The address of the token being transferred
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address token, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        uint256 reserve     = underlyingReserves[safeHandler][token];

        require(reserve > 0, "CurveV2MaxSafeSaviour/no-reserves");
        delete(underlyingReserves[safeHandler][token]);

        ERC20Like(token).transfer(dst, reserve);

        emit GetReserves(msg.sender, safeHandler, token, reserve, dst);
    }

    // --- Adding/Withdrawing Cover ---
    /**
    * @notice Deposit lpToken in the contract in order to provide cover for a specific SAFE managed by the SAFE Manager
    * @param collateralType The collateral type used in the SAFE
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param lpTokenAmount The amount of lpToken to deposit
    */
    function deposit(bytes32 collateralType, uint256 safeID, uint256 lpTokenAmount)
      external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        require(lpTokenAmount > 0, "CurveV2MaxSafeSaviour/null-lp-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "CurveV2MaxSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(address(safeEngine)).safes(collateralType, safeHandler);
        require(safeDebt > 0, "CurveV2MaxSafeSaviour/safe-does-not-have-debt");

        // Update the lpToken balance used to cover the SAFE and transfer tokens to this contract
        lpTokenCover[collateralType][safeHandler] = add(lpTokenCover[collateralType][safeHandler], lpTokenAmount);
        require(lpToken.transferFrom(msg.sender, address(this), lpTokenAmount), "CurveV2MaxSafeSaviour/could-not-transfer-lp");

        emit Deposit(msg.sender, collateralType, safeHandler, lpTokenAmount);
    }
    /**
    * @notice Withdraw lpToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param collateralType The collateral type in the covered SAFE
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside the SAFE Manager
    * @param lpTokenAmount The amount of lpToken to withdraw
    * @param dst The address that will receive the LP tokens
    */
    function withdraw(bytes32 collateralType, uint256 safeID, uint256 lpTokenAmount, address dst)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(lpTokenAmount > 0, "CurveV2MaxSafeSaviour/null-lp-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(lpTokenCover[collateralType][safeHandler] >= lpTokenAmount, "CurveV2MaxSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        lpTokenCover[collateralType][safeHandler] = sub(lpTokenCover[collateralType][safeHandler], lpTokenAmount);
        lpToken.transfer(dst, lpTokenAmount);

        emit Withdraw(msg.sender, collateralType, safeHandler, dst, lpTokenAmount);
    }

    // --- Saving Logic ---
    /**
    * @notice Saves a SAFE by withdrawing liquidity and repaying debt and/or adding more collateral
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of LP tokens that were used to withdraw liquidity as well as the amount of
    *         system coins sent to the keeper as their payment (this implementation always returns 0)
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "CurveV2MaxSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "CurveV2MaxSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Check that the SAFE has a non null amount of LP tokens covering it
        require(
          either(lpTokenCover[collateralType][safeHandler] > 0, underlyingReserves[safeHandler][address(systemCoin)] > 0),
          "CurveV2MaxSafeSaviour/null-cover"
        );

        // Tax the collateral
        taxCollector.taxSingle(collateralType);

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Remove all liquidity from Curve
        uint256 totalCover = lpTokenCover[collateralType][safeHandler];
        removeLiquidity(collateralType, safeHandler);

        // Record tokens that are not system coins and put them in reserves
        uint256 sysCoinBalance          = underlyingReserves[safeHandler][address(systemCoin)];
        uint256 collateralTokenBalance  = collateralToken.balanceOf(address(this));

        // store length to save gas
        uint256 length = removedCoinLiquidity.length;

        for (uint i = 0; i != length; ++i) {
          if (removedCoinLiquidity[i] == 0) {
            continue;
          }

          if (poolTokens[i] == address(systemCoin)) {
            sysCoinBalance = add(sysCoinBalance, removedCoinLiquidity[i]);
          } else if (poolTokens[i] != address(collateralToken)) {
            underlyingReserves[safeHandler][poolTokens[i]] = add(
              underlyingReserves[safeHandler][poolTokens[i]], removedCoinLiquidity[i]
            );
          }
        }

        // Get the amounts of tokens sent to the keeper as payment
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(safeHandler, oracleRelayer.redemptionPrice(), sysCoinBalance, collateralTokenBalance);

        // There must be tokens that go to the keeper
        require(either(keeperSysCoins > 0, keeperCollateralCoins > 0), "CurveV2MaxSafeSaviour/cannot-pay-keeper");

        // Compute how many coins remain after paying the keeper
        sysCoinBalance        = sub(sysCoinBalance, keeperSysCoins);
        collateralTokenBalance = sub(collateralTokenBalance, keeperCollateralCoins);

        // There must be tokens that are used to save the SAFE
        require(either(sysCoinBalance > 0, collateralTokenBalance > 0), "CurveV2MaxSafeSaviour/cannot-save-safe");

        // Get the amount of tokens used to top up the SAFE
        uint256 safeDebtRepaid = getTokensForSaving(collateralType, safeHandler, sysCoinBalance);

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance         = sub(sysCoinBalance, safeDebtRepaid);

        // Update system coin reserves
        underlyingReserves[safeHandler][address(systemCoin)]      = sysCoinBalance;
        underlyingReserves[safeHandler][address(collateralToken)] = collateralTokenBalance;

        // Save the SAFE
        if (safeDebtRepaid > 0) {
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

        if (collateralTokenBalance > 0) {
          // Approve collateralToken to the collateral join contract
          collateralToken.approve(address(collateralJoin), collateralTokenBalance);

          // Join collateralToken in the system and add it in the saved SAFE
          collateralJoin.join(address(this), collateralTokenBalance);
          safeEngine.modifySAFECollateralization(
            collateralType,
            safeHandler,
            address(this),
            address(0),
            int256(collateralTokenBalance),
            int256(0)
          );
        }

        // Check the SAFE is saved
        require(safeIsAfloat(collateralType, safeHandler), "CurveV2MaxSafeSaviour/safe-not-saved");

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

    // --- Internal Logic ---
    /**
     * @notice Remove all Curve liquidity protecting a specific SAFE and return the amounts of all returned tokens
     * @param collateralType The collateral type of the SAFE whose cover is now used
     * @param safeHandler The handler of the SAFE for which we withdraw Curve liquidity
     */
    function removeLiquidity(bytes32 collateralType, address safeHandler) internal {
        // Wipe storage
        delete(removedCoinLiquidity);
        require(removedCoinLiquidity.length == 0, "CurveV2MaxSafeSaviour/cannot-wipe-storage");

        if (lpTokenCover[collateralType][safeHandler] == 0) return;

        // store length to save gas
        uint256 length = poolTokensCount;

        for (uint i = 0; i != length; ++i) {
          removedCoinLiquidity.push(ERC20Like(poolTokens[i]).balanceOf(address(this)));
        }

        uint256 totalCover = lpTokenCover[collateralType][safeHandler];
        delete(lpTokenCover[collateralType][safeHandler]);

        lpToken.approve(address(curvePool), totalCover);
        if (length == 2) {
          uint256[2] memory minTokensToWithdraw;
          curvePool.remove_liquidity(totalCover, minTokensToWithdraw);
        } else if (length == 3) {
          uint256[3] memory minTokensToWithdraw;
          curvePool.remove_liquidity(totalCover, minTokensToWithdraw);
        } else {
          uint256[4] memory minTokensToWithdraw;
          curvePool.remove_liquidity(totalCover, minTokensToWithdraw);
        }

        for (uint i = 0; i != length; ++i) {
          removedCoinLiquidity[i] = sub(ERC20Like(poolTokens[i]).balanceOf(address(this)), removedCoinLiquidity[i]);
        }
    }

    // --- Getters ---
    /**
    * @notice Must be implemented according to the interface although it always returns 0
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        return 0;
    }
    /**
    * @notice Must be implemented according to the interface although it always returns false
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        return false;
    }
    /**
    * @notice Returns whether a SAFE can be currently saved; in this implementation it always returns false
    * @param safeHandler The safe handler associated with the SAFE
    */
    function canSave(bytes32 collateralType, address safeHandler) override external returns (bool) {
        // Fetch the redemption price first
        uint256 redemptionPrice = oracleRelayer.redemptionPrice();

        uint256 systemCoinAmount = underlyingReserves[safeHandler][address(systemCoin)];
        uint256 collateralAmount = collateralToken.balanceOf(address(this));

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
        uint256 safeDebtRepaid = getTokensForSaving(collateralType, safeHandler, systemCoinAmount);
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

        // If there are some tokens used to repay the keeper, return true
        if (either(keeperSysCoins > 0, keeperCollateralCoins > 0)) {
          return true;
        }

        return false;
    }
    /**
    * @notice Return the total amount of LP tokens used to save a specific SAFE
    * @param collateralType The SAFE collateral type
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of LP tokens used to save a SAFE
    */
    function tokenAmountUsedToSave(bytes32 collateralType, address safeHandler) override public returns (uint256) {
        return lpTokenCover[collateralType][safeHandler];
    }
    /**
    * @notice Fetch the collateral's price
    */
    function getCollateralPrice() public view returns (uint256) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        if (ethFSM == address(0)) return 0;

        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
    }
    /**
    * @notice Fetch the system coin's market price
    */
    function getSystemCoinMarketPrice() public view returns (uint256) {
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
    }
    /**
    * @notice Return the amount of system coins used to save a SAFE
    * @param collateralType The SAFE collateral type
    * @param safeHandler The handler/address of the targeted SAFE
    * @param coinsLeft System coins left to save the SAFE after paying the liquidation keeper
    */
    function getTokensForSaving(
      bytes32 collateralType,
      address safeHandler,
      uint256 coinsLeft
    ) public view returns (uint256) {
        if (coinsLeft == 0) {
            return 0;
        }

        // Get the default CRatio for the SAFE
        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(address(safeEngine)).safes(collateralType, safeHandler);
        if (safeDebt == 0) {
            return 0;
        }

        // See how many system coins can be used to save the SAFE
        uint256 usedSystemCoins;
        (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralType);
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralType);

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
    /**
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
    /**
    * @notice Returns whether a SAFE is afloat
    * @param safeHandler The handler of the SAFE to verify
    */
    function safeIsAfloat(bytes32 collateralType, address safeHandler) public view returns (bool) {
        (, uint256 accumulatedRate, , , , uint256 liquidationPrice) = safeEngine.collateralTypes(collateralType);
        (uint256 safeCollateral, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);

        return (
          mul(safeCollateral, liquidationPrice) > mul(safeDebt, accumulatedRate)
        );
    }
    /**
    * @notice Get the accumulated interest rate for a specific collateral type as well as its current liquidation price
    * @param collateralType The collateral type for which to retrieve the rate and the price
    */
    function getAccumulatedRateAndLiquidationPrice(bytes32 collateralType)
      public view returns (uint256 accumulatedRate, uint256 liquidationPrice) {
        (, accumulatedRate, , , , liquidationPrice) = safeEngine.collateralTypes(collateralType);
    }
}
