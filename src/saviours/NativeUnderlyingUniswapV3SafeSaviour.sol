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
pragma experimental ABIEncoderV2;

import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../interfaces/UniswapV3NonFungiblePositionManagerLike.sol";

import "../integrations/uniswap/uni-v3/UniswapV3FeeCalculator.sol";
import "../integrations/uniswap/uni-v3/libs/PoolAddress.sol";

import "../math/SafeMath.sol";

contract NativeUnderlyingUniswapV3SafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "NativeUnderlyingUniswapV3SafeSaviour/account-not-authorized");
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
          "NativeUnderlyingUniswapV3SafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Structs ---
    struct NFTCollateral {
        uint256 firstId;
        uint256 secondId;
    }

    // --- Variables ---
    // Fee for the target pool
    uint24                                  public poolFee;
    // Uniswap pool address
    address                                 public targetUniswapPool;

    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                                 public restrictUsage;

    // Whether the system coin is token0 in the Uniswap pool or not
    bool                                    public isSystemCoinToken0;
    // NFTs used to back safes
    mapping(address => NFTCollateral)       public lpTokenCover;
    // Amount of system coin that Safe owners can get back
    mapping(address => uint256)             public underlyingReserves;
    // NFT position manager for Uniswap v3
    UniswapV3NonFungiblePositionManagerLike public positionManager;
    // Uniswap fee calculator for each position
    UniswapV3FeeCalculator                  public feeCalculator;
    // The ERC20 system coin
    ERC20Like                               public systemCoin;
    // The system coin join contract
    CoinJoinLike                            public coinJoin;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike                      public collateralJoin;
    // The collateral token
    ERC20Like                               public collateralToken;
    // Oracle providing the system coin price feed
    PriceFeedLike                           public systemCoinOrcl;
    // Contract that defines desired CRatios for each Safe after it is saved
    SaviourCRatioSetterLike                 public cRatioSetter;

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
      uint256 nftId
    );
    event Withdraw(
      address indexed caller,
      address indexed safeHandler,
      address dst,
      uint256 nftId
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
        address liquidationEngine_,
        address taxCollector_,
        address oracleRelayer_,
        address safeManager_,
        address saviourRegistry_,
        address positionManager_,
        address feeCalculator_,
        uint24  poolFee_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-collateral-join");
        require(oracleRelayer_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-tax-collector");
        require(safeManager_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-saviour-registry");
        require(positionManager_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-positions-manager");
        require(feeCalculator_ != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-fee-calculator");
        require(minKeeperPayoutValue_ > 0, "NativeUnderlyingUniswapV3SafeSaviour/invalid-min-payout-value");
        require(poolFee_ > 0, "NativeUnderlyingUniswapV3SafeSaviour/null-pool-fee");

        authorizedAccounts[msg.sender] = 1;

        isSystemCoinToken0   = isSystemCoinToken0_;
        minKeeperPayoutValue = minKeeperPayoutValue_;
        poolFee              = poolFee_;

        coinJoin             = CoinJoinLike(coinJoin_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        taxCollector         = TaxCollectorLike(taxCollector_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        feeCalculator        = UniswapV3FeeCalculator(feeCalculator_);
        positionManager      = UniswapV3NonFungiblePositionManagerLike(positionManager_);
        collateralToken      = ERC20Like(collateralJoin.collateral());

        oracleRelayer.redemptionPrice();

        // Avoid stack too deep
        {
          (address token0, address token1) = (isSystemCoinToken0) ?
            (address(systemCoin), address(collateralToken)) : (address(collateralToken), address(systemCoin));

          PoolAddress.PoolKey memory key = PoolAddress.PoolKey(token0, token1, poolFee);
          targetUniswapPool              = PoolAddress.computeAddress(positionManager.factory(), key);
        }

        require(targetUniswapPool != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-target-pool");
        require(collateralJoin.contractEnabled() == 1, "NativeUnderlyingUniswapV3SafeSaviour/join-disabled");
        require(address(collateralToken) != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-col-token");
        require(address(safeEngine) != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("taxCollector", taxCollector_);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
        emit ModifyParameters("positionManager", positionManager_);
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
            require(val > 0, "NativeUnderlyingUniswapV3SafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "NativeUnderlyingUniswapV3SafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("NativeUnderlyingUniswapV3SafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-data");

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
        else if (parameter == "feeCalculator") {
            feeCalculator = UniswapV3FeeCalculator(data);
        }
        else revert("NativeUnderlyingUniswapV3SafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Transferring Reserves ---
    /*
    * @notify Get back system coins that were withdrawn from Uniswap and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        uint256 reserve     = underlyingReserves[safeHandler];

        require(reserve > 0, "NativeUnderlyingUniswapV3SafeSaviour/no-reserves");
        delete(underlyingReserves[safeManager.safes(safeID)]);

        systemCoin.transfer(dst, reserve);

        emit GetReserves(msg.sender, safeHandler, reserve, dst);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit a NFT position in the contract in order to provide cover for a specific SAFE managed by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param tokenId The ID of the NFTed position
    */
    function deposit(uint256 safeID, uint256 tokenId) external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        require(
          either(lpTokenCover[safeHandler].firstId == 0, lpTokenCover[safeHandler].secondId == 0),
          "NativeUnderlyingUniswapV3SafeSaviour/cannot-add-more-positions"
        );

        // Fetch position details
        ( ,
          ,
          address token0_,
          address token1_,
          uint24 fee_,
          ,,,,,,
        ) = positionManager.positions(tokenId);

        // Position checks
        require(token0_ != token1_, "NativeUnderlyingUniswapV3SafeSaviour/same-tokens");
        require(
          either(address(systemCoin) == token0_, address(systemCoin) == token1_),
          "NativeUnderlyingUniswapV3SafeSaviour/not-sys-coin-pool"
        );
        require(
          either(address(collateralToken) == token0_, address(collateralToken) == token1_),
          "NativeUnderlyingUniswapV3SafeSaviour/not-collateral-token-pool"
        );

        // Check that the SAFE exists inside GebSafeManager
        require(safeHandler != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "NativeUnderlyingUniswapV3SafeSaviour/safe-does-not-have-debt");

        // Update the NFT positions used to cover the SAFE and transfer the NFT to this contract
        if (lpTokenCover[safeHandler].firstId == 0) {
          lpTokenCover[safeHandler].firstId = tokenId;
        } else {
          lpTokenCover[safeHandler].secondId = tokenId;
        }

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        require(
          positionManager.ownerOf(tokenId) == address(this),
          "NativeUnderlyingUniswapV3SafeSaviour/cannot-transfer-position"
        );

        emit Deposit(msg.sender, safeHandler, tokenId);
    }
    /*
    * @notice Withdraw lpToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside the SAFE Manager
    * @param lpTokenAmount The amount of lpToken to withdraw
    * @param dst The address that will receive the LP tokens
    */
    function withdraw(uint256 safeID, uint256 tokenId, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);

        require(
          positionManager.ownerOf(tokenId) == address(this),
          "NativeUnderlyingUniswapV3SafeSaviour/position-not-in-contract"
        );
        require(
          either(lpTokenCover[safeHandler].firstId == tokenId, lpTokenCover[safeHandler].secondId == tokenId),
          "NativeUnderlyingUniswapV3SafeSaviour/cannot-add-more-positions"
        );

        // Update NFT entries
        if (lpTokenCover[safeHandler].firstId == tokenId) {
          lpTokenCover[safeHandler].firstId  = lpTokenCover[safeHandler].secondId;
        }
        lpTokenCover[safeHandler].secondId = 0;

        // Transfer NFT to the caller
        positionManager.transferFrom(address(this), dst, tokenId);

        emit Withdraw(msg.sender, safeHandler, dst, tokenId);
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
        require(address(liquidationEngine) == msg.sender, "NativeUnderlyingUniswapV3SafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "NativeUnderlyingUniswapV3SafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        require(collateralType == collateralJoin.collateralType(), "NativeUnderlyingUniswapV3SafeSaviour/invalid-collateral-type");

        // Check that the SAFE has a non null amount of NFT tokens covering it
        require(
          lpTokenCover[safeHandler].firstId != 0,
          "NativeUnderlyingUniswapV3SafeSaviour/no-cover"
        );

        // Get current sys coin balance
        uint256 sysCoinBalance = systemCoin.balanceOf(address(this));

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Store cover amount in local var
        uint256 totalCover;
        if (lpTokenCover[safeHandler].secondId != 0) {
          totalCover = 2;
        } else {
          totalCover = 1;
        }

        // Withdraw all liquidity
        if (lpTokenCover[safeHandler].secondId != 0) removeLiquidity(lpTokenCover[safeHandler].secondId, safeHandler);
        removeLiquidity(lpTokenCover[safeHandler].firstId, safeHandler);

        // Get amounts withdrawn
        sysCoinBalance = sub(systemCoin.balanceOf(address(this)), sysCoinBalance);

        // Get the amounts of tokens sent to the keeper as payment
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(
            safeHandler,
            oracleRelayer.redemptionPrice(),
            sysCoinBalance,
            collateralToken.balanceOf(address(this))
          );

        // There must be tokens that go to the keeper
        require(either(keeperSysCoins > 0, keeperCollateralCoins > 0), "NativeUnderlyingUniswapV3SafeSaviour/cannot-pay-keeper");

        // Get the amount of tokens used to top up the SAFE
        (uint256 safeDebtRepaid, uint256 safeCollateralAdded) =
          getTokensForSaving(
            safeHandler,
            oracleRelayer.redemptionPrice(),
            sub(sysCoinBalance, keeperSysCoins),
            sub(collateralToken.balanceOf(address(this)), keeperCollateralCoins)
          );

        // There must be tokens used to save the SAVE
        require(either(safeDebtRepaid > 0, safeCollateralAdded > 0), "NativeUnderlyingUniswapV3SafeSaviour/cannot-save-safe");

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance = sub(sysCoinBalance, add(safeDebtRepaid, keeperSysCoins));

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

        if (safeCollateralAdded > 0) {
          // Approve collateralToken to the collateral join contract
          collateralToken.approve(address(collateralJoin), safeCollateralAdded);

          // Join collateralToken in the system and add it in the saved SAFE
          collateralJoin.join(address(this), safeCollateralAdded);
          safeEngine.modifySAFECollateralization(
            collateralType,
            safeHandler,
            address(this),
            address(0),
            int256(safeCollateralAdded),
            int256(0)
          );
        }

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
     * @notice Remove all liquidity from the positions covering a specific SAFE
     * @param tokenId The ID of the position from which we withdraw liquidity
     * @param safeHandler The handler of the SAFE for which we withdraw Uniswap liquidity
     */
    function removeLiquidity(uint256 tokenId, address safeHandler) internal {
        // Collect fees first
        UniswapV3NonFungiblePositionManagerLike.CollectParams memory collectParams =
          UniswapV3NonFungiblePositionManagerLike.CollectParams(
            tokenId, address(this), uint128(-1), uint128(-1)
        );

        positionManager.collect(collectParams);

        // Withdraw liquidity next
        ( ,,,,,,,
          uint128 liquidity,
          ,,,
        ) = positionManager.positions(tokenId);

        UniswapV3NonFungiblePositionManagerLike.DecreaseLiquidityParams memory decreaseParams =
          UniswapV3NonFungiblePositionManagerLike.DecreaseLiquidityParams(
            tokenId, liquidity, 0, 0, block.timestamp
        );

        positionManager.decreaseLiquidity(decreaseParams);

        // Checks
        ( ,,,,,,,
          liquidity,
          ,,,
        ) = positionManager.positions(tokenId);
        require(liquidity == 0, "NativeUnderlyingUniswapV3SafeSaviour/invalid-liquidity-decrease");
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
    /**
     * @notice Return the total amount of tokens and fees that can be withdrawn from the current NFTS protecting a SAFE
     * @param safeHandler The safe handler associated with the SAFE for which we get the total withdrawn tokens
     */
    function getTotalWithdrawnTokens(address safeHandler)
      public view returns (uint256 totalSystemCoinsWithdrawn, uint256 totalCollateralTokensWithdrawn) {
        // Get current sys coin balance
        uint256 sysCoinBalance = systemCoin.balanceOf(address(this));

        if (lpTokenCover[safeHandler].secondId != 0) {
          (uint256 amount0Fees, uint256 amount1Fees) =
            feeCalculator.getUncollectedFees(targetUniswapPool, lpTokenCover[safeHandler].secondId);

          ( ,,,,,,,,,,
            uint128 tokensOwed0,
            uint128 tokensOwed1
          ) = positionManager.positions(lpTokenCover[safeHandler].secondId);

          if (isSystemCoinToken0) {
            totalSystemCoinsWithdrawn      = add(totalSystemCoinsWithdrawn, add(amount0Fees, uint256(tokensOwed0)));
            totalCollateralTokensWithdrawn = add(totalCollateralTokensWithdrawn, add(amount1Fees, uint256(tokensOwed1)));
          } else {
            totalSystemCoinsWithdrawn      = add(totalSystemCoinsWithdrawn, add(amount1Fees, uint256(tokensOwed1)));
            totalCollateralTokensWithdrawn = add(totalCollateralTokensWithdrawn, add(amount0Fees, uint256(tokensOwed0)));
          }
        }

        {
          (uint256 amount0Fees, uint256 amount1Fees) =
            feeCalculator.getUncollectedFees(targetUniswapPool, lpTokenCover[safeHandler].firstId);

          ( ,,,,,,,,,,
            uint128 tokensOwed0,
            uint128 tokensOwed1
          ) = positionManager.positions(lpTokenCover[safeHandler].firstId);

          if (isSystemCoinToken0) {
            totalSystemCoinsWithdrawn      = add(totalSystemCoinsWithdrawn, add(amount0Fees, uint256(tokensOwed0)));
            totalCollateralTokensWithdrawn = add(totalCollateralTokensWithdrawn, add(amount1Fees, uint256(tokensOwed1)));
          } else {
            totalSystemCoinsWithdrawn      = add(totalSystemCoinsWithdrawn, add(amount1Fees, uint256(tokensOwed1)));
            totalCollateralTokensWithdrawn = add(totalCollateralTokensWithdrawn, add(amount0Fees, uint256(tokensOwed0)));
          }
        }
    }
    /*
    * @notify Returns whether a SAFE can be currently saved
    * @param safeHandler The safe handler associated with the SAFE
    */
    function canSave(bytes32, address safeHandler) override external returns (bool) {
        // Check that the SAFE has a non null amount of NFT tokens covering it
        if (lpTokenCover[safeHandler].firstId != 0) {
          return false;
        }

        // See how many tokens can be withdrawn from the NFTs + take into account fees
        (uint256 totalSystemCoinsWithdrawn, uint256 totalCollateralTokensWithdrawn) =
          getTotalWithdrawnTokens(safeHandler);

        // Calculate keeper fees and amount of tokens used to save the SAFE
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(
            safeHandler,
            oracleRelayer.redemptionPrice(),
            totalSystemCoinsWithdrawn,
            totalCollateralTokensWithdrawn
          );

        (uint256 safeDebtRepaid, uint256 safeCollateralAdded) =
          getTokensForSaving(
            safeHandler,
            oracleRelayer.redemptionPrice(),
            sub(totalSystemCoinsWithdrawn, keeperSysCoins),
            sub(totalCollateralTokensWithdrawn, keeperCollateralCoins)
          );

        // If there are some tokens used to repay the keeper, return true
        if (both(
          either(safeDebtRepaid > 0, safeCollateralAdded > 0),
          either(keeperSysCoins > 0, keeperCollateralCoins > 0)
        )) {
          return true;
        }

        return false;
    }
    /*
    * @notice Return the total amount of NFT tokens used to save a SAFE
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of NFT tokens used to save a SAFE
    */
    function tokenAmountUsedToSave(bytes32, address safeHandler) override public returns (uint256) {
        if (lpTokenCover[safeHandler].secondId != 0) {
          return 2;
        } else {
          return 1;
        }
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
    * @notify Get the target collateralization ratio that a SAFE should have after it's saved
    * @param safeHandler The handler/address of the SAFE whose target collateralization ratio is retrieved
    */
    function getTargetCRatio(address safeHandler) public view returns (uint256) {
        bytes32 collateralType = collateralJoin.collateralType();
        uint256 defaultCRatio  = cRatioSetter.defaultDesiredCollateralizationRatios(collateralType);
        uint256 targetCRatio   = (cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler) == 0) ?
          defaultCRatio : cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler);
        return targetCRatio;
    }
    /*
    * @notice Return the amount of system coins and/or collateral tokens used to save a SAFE
    * @param safeHandler The handler/address of the targeted SAFE
    * @param redemptionPrice The system coin redemption price used in calculations
    * @param coinsLeft System coins left to save the SAFE after paying the liquidation keeper
    * @param collateralleft Collateral tokens left to save the SAFE after paying the liquidation keeper
    */
    function getTokensForSaving(
      address safeHandler,
      uint256 redemptionPrice,
      uint256 coinsLeft,
      uint256 collateralLeft
    ) public view returns (uint256, uint256) {
        if (either(redemptionPrice == 0, both(coinsLeft == 0, collateralLeft == 0))) {
            return (0, 0);
        }

        // Get the default CRatio for the SAFE
        (uint256 depositedCollateralToken, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        if (safeDebt == 0) {
            return (0, 0);
        }

        // See how many system coins can be used to save the SAFE
        uint256 usedSystemCoins;
        if (coinsLeft > 0) {
          (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralJoin.collateralType());
          if (coinsLeft >= safeDebt) usedSystemCoins = safeDebt;
          else if (debtFloor < safeDebt) {
            usedSystemCoins = min(sub(safeDebt, debtFloor), coinsLeft);
          }
        }

        // See if the SAFE can be saved by adding all collateral left
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralJoin.collateralType());
        bool safeSaved = (
          mul(add(depositedCollateralToken, collateralLeft), liquidationPrice) <
          mul(sub(safeDebt, usedSystemCoins), accumulatedRate)
        );

        if (safeSaved) return (usedSystemCoins, collateralLeft);
        else {
          return (0, 0);
        }
    }
    /*
    * @notice Return the amount of system coins and/or collateral tokens used to pay a keeper
    * @param safeHandler The handler/address of the targeted SAFE
    * @param redemptionPrice The system coin redemption price used in calculations
    * @param sysCoinsFromLP System coins withdrawn from Uniswap
    * @param collateralFromLP Collateral tokens withdrawn from Uniswap
    */
    function getKeeperPayoutTokens(
      address safeHandler,
      uint256 redemptionPrice,
      uint256 sysCoinsFromLP,
      uint256 collateralFromLP
    ) public view returns (uint256, uint256) {
        if (both(sysCoinsFromLP == 0, collateralFromLP == 0)) return (0, 0);

        // Get the system coin and collateral market prices
        uint256 collateralPrice    = getCollateralPrice();
        uint256 sysCoinMarketPrice = getSystemCoinMarketPrice();
        if (either(collateralPrice == 0, sysCoinMarketPrice == 0)) {
            return (0, 0);
        }

        // Check if the keeper can get system coins and if yes, compute how many
        uint256 keeperSysCoins;
        if (sysCoinsFromLP > 0) {
            uint256 payoutInSystemCoins = div(mul(minKeeperPayoutValue, WAD), sysCoinMarketPrice);

            if (payoutInSystemCoins <= sysCoinsFromLP) {
              return (payoutInSystemCoins, 0);
            } else {
              keeperSysCoins = sysCoinsFromLP;
            }
        }

        // Calculate how much collateral the keeper will get
        uint256 remainingKeeperPayoutValue = sub(minKeeperPayoutValue, mul(keeperSysCoins, sysCoinMarketPrice) / WAD);
        uint256 collateralTokenNeeded      = div(mul(remainingKeeperPayoutValue, WAD), collateralPrice);

        // If there are enough collateral tokens retreived from LP in order to pay the keeper, return the token amounts
        if (collateralTokenNeeded <= collateralFromLP) {
          return (keeperSysCoins, collateralTokenNeeded);
        } else {
          // Otherwise, return zeroes
          return (0, 0);
        }
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
