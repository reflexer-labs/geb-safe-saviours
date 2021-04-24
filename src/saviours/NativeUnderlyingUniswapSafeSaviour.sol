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

pragma solidity 0.6.7;

import "../interfaces/UniswapLiquidityManagerLike.sol";
import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract NativeUnderlyingUniswapSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "NativeUnderlyingUniswapSafeSaviour/account-not-authorized");
        _;
    }

    // --- Structs ---
    struct Reserves {
        uint256 systemCoins;
        uint256 collateralCoins;
    }

    // --- Variables ---
    // Whether the system coin is token0 in the Uniswap pool or not
    bool                           public isSystemCoinToken0;
    // Amount of LP tokens currently protecting each position
    mapping(address => uint256)    public lpTokenCover;
    // Amount of system coin/collateral tokens that Safe owners can get back
    mapping(address => Reserves)   public underlyingReserves;
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
    // Contract that defines desired CRatios for each Safe after it is saved
    SaviourCRatioSetterLike        public cRatioSetter;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
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
      uint256 lpTokenAmount
    );
    event GetReserves(
      address indexed caller,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      uint256 collateralAmount
    );

    constructor(
        bool isSystemCoinToken0_,
        address coinJoin_,
        address collateralJoin_,
        address cRatioSetter_,
        address systemCoinOrcl_,
        address liquidationEngine_,
        address oracleRelayer_,
        address safeManager_,
        address saviourRegistry_,
        address liquidityManager_,
        address lpToken_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-collateral-join");
        require(cRatioSetter_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-cratio-setter");
        require(systemCoinOrcl_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-liquidation-engine");
        require(safeManager_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-saviour-registry");
        require(liquidityManager_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-liq-manager");
        require(lpToken_ != address(0), "NativeUnderlyingUniswapSafeSaviour/null-lp-token");
        require(minKeeperPayoutValue_ > 0, "NativeUnderlyingUniswapSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        isSystemCoinToken0   = isSystemCoinToken0_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        coinJoin             = CoinJoinLike(coinJoin_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        cRatioSetter         = SaviourCRatioSetterLike(cRatioSetter_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoinOrcl       = PriceFeedLike(systemCoinOrcl_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        liquidityManager     = UniswapLiquidityManagerLike(liquidityManager_);
        lpToken              = ERC20Like(lpToken_);

        systemCoinOrcl.read();
        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(collateralJoin.contractEnabled() == 1, "NativeUnderlyingUniswapSafeSaviour/join-disabled");
        require(address(safeEngine) != address(0), "NativeUnderlyingUniswapSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "NativeUnderlyingUniswapSafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("systemCoinOrcl", systemCoinOrcl_);
        emit ModifyParameters("liquidityManager", liquidityManager_);
    }

    // --- Administration ---
    /**
     * @notice Modify an uint256 param
     * @param parameter The name of the parameter
     * @param val New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        require(val > 0, "NativeUnderlyingUniswapSafeSaviour/null-value");

        if (parameter == "minKeeperPayoutValue") {
            minKeeperPayoutValue = val;
        }
        else revert("NativeUnderlyingUniswapSafeSaviour/modify-unrecognized-param");
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "NativeUnderlyingUniswapSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
            systemCoinOrcl.read();
            systemCoinOrcl.getResultWithValidity();
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "liquidityManager") {
            liquidityManager = UniswapLiquidityManagerLike(data);
        }
        else revert("NativeUnderlyingUniswapSafeSaviour/modify-unrecognized-param");
    }

    // --- Transferring Funds ---
    /*
    * @notify Get back system coins or collateral tokens that were withdrawn from Uniswap and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    */
    function getReserves(uint256 safeID) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        Reserves memory reserves = underlyingReserves[safeHandler];

        require(either(reserves.systemCoins > 0, reserves.collateralCoins > 0), "NativeUnderlyingUniswapSafeSaviour/no-reserves");
        delete(underlyingReserves[safeManager.safes(safeID)]);

        if (reserves.systemCoins > 0) {
          systemCoin.transfer(msg.sender, reserves.systemCoins);
        }

        if (reserves.collateralCoins > 0) {
          collateralToken.transfer(msg.sender, reserves.collateralCoins);
        }

        emit GetReserves(msg.sender, safeHandler, reserves.systemCoins, reserves.collateralCoins);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit lpToken in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param lpTokenAmount The amount of collateralToken to deposit
    */
    function deposit(uint256 safeID, uint256 lpTokenAmount) external liquidationEngineApproved(address(this)) nonReentrant {
        require(lpTokenAmount > 0, "NativeUnderlyingUniswapSafeSaviour/null-lp-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "NativeUnderlyingUniswapSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "NativeUnderlyingUniswapSafeSaviour/safe-does-not-have-debt");

        // Update the lpToken balance used to cover the SAFE and transfer tokens to this contract
        lpTokenCover[safeHandler] = add(lpTokenCover[safeHandler], lpTokenAmount);
        require(lpToken.transferFrom(msg.sender, address(this), lpTokenAmount), "NativeUnderlyingUniswapSafeSaviour/could-not-transfer-lp");

        emit Deposit(msg.sender, safeHandler, lpTokenAmount);
    }
    /*
    * @notice Withdraw lpToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param lpTokenAmount The amount of lpToken to withdraw
    */
    function withdraw(uint256 safeID, uint256 lpTokenAmount) external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(lpTokenAmount > 0, "NativeUnderlyingUniswapSafeSaviour/null-lp-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(lpTokenCover[safeHandler] >= lpTokenAmount, "NativeUnderlyingUniswapSafeSaviour/not-enough-to-withdraw");

        // Withdraw cover and transfer collateralToken to the caller
        lpTokenCover[safeHandler] = sub(lpTokenCover[safeHandler], lpTokenAmount);
        lpToken.transfer(msg.sender, lpTokenAmount);

        emit Withdraw(msg.sender, safeHandler, lpTokenAmount);
    }

    // --- Saving Logic ---
    /*
    *
    */
    function saveSAFE(address,bytes32,address) override external returns (bool,uint256,uint256) {

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
    * @notice Determine whether a SAFE can be saved with the current amount of lpToken deposited as cover for it
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(bytes32, address safeHandler) override external returns (bool) {
        (uint256 lpTokensForCover, uint256 systemCoinsForCover, uint256 collateralTokensForCover) = amountsUsedToSave(safeHandler);
        if (either(lpTokensForCover > lpTokenCover[safeHandler], either(lpTokensForCover == MAX_UINT, lpTokensForCover == 0))) return false;

        // calculate rewards given to the keeper
        (bool canReward, , , ) =
          getFundsForKeeperPayout(safeHandler, lpTokensForCover, systemCoinsForCover, collateralTokensForCover);

        return canReward;
    }
    /*
    * @notice Calculate the amount of lpToken used to save a SAFE and bring its CRatio to the desired level (only by using system coins)
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of collateralToken used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(bytes32, address safeHandler) override public returns (uint256) {
        if (lpTokenCover[safeHandler] == 0) return 0;

        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        uint256 priceFeedValue = getCollateralPrice();

        // If the SAFE doesn't have debt or if the price feed is null, abort
        if (either(safeDebt == 0, priceFeedValue == 0)) {
            return MAX_UINT;
        }

        uint256 redemptionPrice      = oracleRelayer.redemptionPrice();
        (uint256 targetDebtAmount, ) = getTargetDebtData(safeHandler, depositedCollateralToken, safeDebt, redemptionPrice, priceFeedValue);
        if (targetDebtAmount == MAX_UINT) return targetDebtAmount;

        // If you need to repay more than the amount of debt in the SAFE (or all the debt), return 0
        if (targetDebtAmount >= safeDebt) {
          return 0;
        } else {
          uint256 lpTokenNeeded;

          if (isSystemCoinToken0) {
            lpTokenNeeded = liquidityManager.getLiquidityFromToken0(targetDebtAmount);
          } else {
            lpTokenNeeded = liquidityManager.getLiquidityFromToken1(targetDebtAmount);
          }

          return lpTokenNeeded;
        }
    }
    /*
    *
    */
    function amountsUsedToSave(address safeHandler) public returns (uint256, uint256, uint256) {
        if (lpTokenCover[safeHandler] == 0) return (0, 0, 0);

        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        uint256 priceFeedValue = getCollateralPrice();

        // If the SAFE doesn't have debt or if the price feed is null, abort
        if (either(safeDebt == 0, priceFeedValue == 0)) {
            return (MAX_UINT, MAX_UINT, MAX_UINT);
        }

        uint256 redemptionPrice                          = oracleRelayer.redemptionPrice();
        (uint256 targetDebtAmount, uint256 targetCRatio) = getTargetDebtData(
          safeHandler, depositedCollateralToken, safeDebt, redemptionPrice, priceFeedValue
        );
        if (targetDebtAmount == MAX_UINT) return (MAX_UINT, MAX_UINT, MAX_UINT);

        // If you need to repay more than the amount of debt in the SAFE (or all the debt), return 0
        if (targetDebtAmount >= safeDebt) {
          return (0, 0, 0);
        } else {
          uint256 lpTokenNeeded;
          if (isSystemCoinToken0) {
            lpTokenNeeded = liquidityManager.getLiquidityFromToken0(targetDebtAmount);
          } else {
            lpTokenNeeded = liquidityManager.getLiquidityFromToken1(targetDebtAmount);
          }

          if (lpTokenNeeded > lpTokenCover[safeHandler]) {
              lpTokenNeeded = lpTokenCover[safeHandler];

              uint256 debtWithdrawn;
              if (isSystemCoinToken0) {
                debtWithdrawn = liquidityManager.getToken0FromLiquidity(lpTokenNeeded);
              } else {
                debtWithdrawn = liquidityManager.getToken1FromLiquidity(lpTokenNeeded);
              }

              (uint256 collateralToLPToken, uint256 collateralTokenNeeded) = getTargetCollateralData(
                sub(safeDebt, debtWithdrawn), redemptionPrice, targetCRatio, priceFeedValue
              );

              if (collateralToLPToken > lpTokenNeeded) {
                return (MAX_UINT, MAX_UINT, MAX_UINT);
              } else if (collateralToLPToken == 0) {
                return (0, 0, 0);
              } else {
                return (lpTokenNeeded, debtWithdrawn, collateralTokenNeeded);
              }
          } else {
              if (lpTokenNeeded == 0) {
                (uint256 collateralToLPToken, uint256 collateralTokenNeeded) = getTargetCollateralData(
                  safeDebt, redemptionPrice, targetCRatio, priceFeedValue
                );

                if (collateralToLPToken > lpTokenCover[safeHandler]) {
                  return (MAX_UINT, MAX_UINT, MAX_UINT);
                } else if (collateralToLPToken == 0) {
                  return (0, 0, 0);
                } else {
                  return (collateralToLPToken, 0, collateralTokenNeeded);
                }
              }

              else return (lpTokenNeeded, targetDebtAmount, 0);
          }
        }
    }
    /*
    *
    */
    function getCollateralPrice() public view returns (uint256) {
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralJoin.collateralType());
        if (ethFSM == address(0)) return 0;

        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
    }
    /*
    *
    */
    function getSystemCoinMarketPrice() public view returns (uint256) {
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();
        if (!hasValidValue) return 0;

        return priceFeedValue;
    }
    /*
    *
    */
    function getTargetCollateralData(
      uint256 safeDebt,
      uint256 redemptionPrice,
      uint256 targetCRatio,
      uint256 priceFeedValue
    ) public view returns (uint256, uint256) {
        if (either(targetCRatio == 0, either(safeDebt == 0, redemptionPrice == 0))) return (0, 0);

        uint256 scaledDownDebtValue = mul(
          add(mul(redemptionPrice, safeDebt) / RAY, ONE), targetCRatio
        ) / HUNDRED;

        uint256 collateralTokenNeeded = div(mul(scaledDownDebtValue, WAD), priceFeedValue);

        // Compute the amount of LP tokens needed to get collateralTokenNeeded collateral tokens from Uniswap
        uint256 collateralToLPToken = (isSystemCoinToken0) ?
          liquidityManager.getLiquidityFromToken1(collateralTokenNeeded) :
          liquidityManager.getLiquidityFromToken0(collateralTokenNeeded);

        return (collateralToLPToken, collateralTokenNeeded);
    }
    /*
    *
    */
    function getTargetDebtData(
      address safeHandler,
      uint256 depositedCollateralToken,
      uint256 safeDebt,
      uint256 redemptionPrice,
      uint256 priceFeedValue
    ) public view returns (uint256, uint256) {
        if (either(depositedCollateralToken == 0, either(safeDebt == 0, redemptionPrice == 0))) return (MAX_UINT, 0);

        uint256 defaultCRatio = cRatioSetter.defaultDesiredCollateralizationRatios(collateralJoin.collateralType());
        if (either(safeDebt == 0, defaultCRatio == 0)) {
            return (MAX_UINT, 0);
        }

        // Calculate the amount of debt that needs to be repaid so the SAFE gets to the target CRatio
        uint256 targetCRatio = (cRatioSetter.desiredCollateralizationRatios(collateralJoin.collateralType(), safeHandler) == 0) ?
          defaultCRatio : cRatioSetter.desiredCollateralizationRatios(collateralJoin.collateralType(), safeHandler);

        uint256 targetDebtAmount = mul(
          mul(HUNDRED, mul(depositedCollateralToken, priceFeedValue) / WAD) / targetCRatio, redemptionPrice
        ) / RAY;

        return (targetDebtAmount, targetCRatio);
    }
    /*
    *
    */
    function getFundsForKeeperPayout(
      address safeHandler,
      uint256 lpTokenForCover,
      uint256 systemCoinForCover,
      uint256 collateralTokenForCover
    ) public view returns (bool, uint256, uint256, uint256) {
        if (lpTokenForCover == 0) return (false, 0, 0, 0);

        uint256 collateralPrice    = getCollateralPrice();
        uint256 sysCoinMarketPrice = getSystemCoinMarketPrice();
        if (either(collateralPrice == 0, sysCoinMarketPrice == 0)) return (false, 0, 0, 0);

        uint256 payoutInCollateral  = mul(minKeeperPayoutValue, WAD) / collateralPrice;
        uint256 payoutInSystemCoins = mul(minKeeperPayoutValue, WAD) / sysCoinMarketPrice;

        if (collateralTokenForCover == 0) {
            uint256 currentCollateralWithdrawn = (isSystemCoinToken0) ?
              liquidityManager.getToken1FromLiquidity(lpTokenForCover) :
              liquidityManager.getToken0FromLiquidity(lpTokenForCover);

            if (payoutInCollateral <= currentCollateralWithdrawn) {
              return (true, 0, 0, payoutInCollateral);
            }

            if (lpTokenForCover < lpTokenCover[safeHandler]) {
                payoutInCollateral          = sub(payoutInCollateral, currentCollateralWithdrawn);
                uint256 extraLPTokensNeeded = (isSystemCoinToken0) ?
                  liquidityManager.getLiquidityFromToken1(payoutInCollateral) :
                  liquidityManager.getLiquidityFromToken0(payoutInCollateral);

                if (both(extraLPTokensNeeded <= sub(lpTokenCover[safeHandler], lpTokenForCover), extraLPTokensNeeded > 0)) {
                    return (true, extraLPTokensNeeded, 0, add(payoutInCollateral, currentCollateralWithdrawn));
                }

                payoutInSystemCoins = mul(payoutInCollateral, collateralPrice) / sysCoinMarketPrice;


            }
        } else if (systemCoinForCover == 0) {
            uint256 extraLPTokensNeeded = (isSystemCoinToken0) ?
              liquidityManager.getLiquidityFromToken1(payoutInCollateral) :
              liquidityManager.getLiquidityFromToken0(payoutInCollateral);

            if (extraLPTokensNeeded <= sub(lpTokenCover[safeHandler], lpTokenForCover)) {
              return (true, extraLPTokensNeeded, 0, payoutInCollateral);
            }
        } else if (both(systemCoinForCover > 0, collateralTokenForCover > 0)) {

        }

        return (false, 0, 0, 0);
    }
}
