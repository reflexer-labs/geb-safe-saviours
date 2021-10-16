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

import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../interfaces/ERC20Like.sol";
import "../interfaces/UniswapV3NonFungiblePositionManagerLike.sol";
import "../interfaces/UniswapV3LiquidityRemoverLike.sol";

import "../math/SafeMath.sol";

contract GeneralUnderlyingMaxUniswapV3SafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "GeneralUnderlyingMaxUniswapV3SafeSaviour/account-not-authorized");
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
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Structs ---
    struct NFTCollateral {
        uint256 firstId;
        uint256 secondId;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                                         public restrictUsage;

    // NFTs used to back safes
    mapping(address => NFTCollateral)               public lpTokenCover;
    // Amount of tokens that were not used to save SAFEs
    mapping(address => mapping(address => uint256)) public underlyingReserves;

    // NFT position manager for Uniswap v3
    UniswapV3NonFungiblePositionManagerLike         public positionManager;
    // Contract helping with liquidity removal
    UniswapV3LiquidityRemoverLike                   public liquidityRemover;
    // The ERC20 system coin
    ERC20Like                                       public systemCoin;
    // The system coin join contract
    CoinJoinLike                                    public coinJoin;
    // The collateral join contract for adding collateral in the system
    CollateralJoinLike                              public collateralJoin;
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
      address token,
      uint256 tokenAmount,
      address dst
    );

    constructor(
        address coinJoin_,
        address collateralJoin_,
        address oracleRelayer_,
        address safeManager_,
        address saviourRegistry_,
        address positionManager_,
        address liquidityRemover_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-collateral-join");
        require(oracleRelayer_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-oracle-relayer");
        require(safeManager_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-saviour-registry");
        require(positionManager_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-positions-manager");
        require(liquidityRemover_ != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-liquidity-remover");
        require(minKeeperPayoutValue_ > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        minKeeperPayoutValue = minKeeperPayoutValue_;

        coinJoin             = CoinJoinLike(coinJoin_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        liquidityRemover     = UniswapV3LiquidityRemoverLike(liquidityRemover_);
        positionManager      = UniswapV3NonFungiblePositionManagerLike(positionManager_);

        oracleRelayer.redemptionPrice();

        require(address(safeEngine) != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("liquidityRemover", liquidityRemover_);
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
            require(val > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "GeneralUnderlyingMaxUniswapV3SafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("GeneralUnderlyingMaxUniswapV3SafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-data");

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
        else if (parameter == "liquidityRemover") {
            liquidityRemover = UniswapV3LiquidityRemoverLike(data);
        }
        else revert("GeneralUnderlyingMaxUniswapV3SafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Transferring Reserves ---
    /*
    * @notify Get back tokens that were withdrawn from Uniswap and not used to save a specific SAFE
    * @param safeID The ID of the safe that was previously saved and has leftover funds that can be withdrawn
    * @param token The address of the token being transferred
    * @param dst The address that will receive the reserve system coins
    */
    function getReserves(uint256 safeID, address token, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);
        uint256 reserve     = underlyingReserves[safeHandler][token];

        require(reserve > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/no-reserves");
        delete(underlyingReserves[safeHandler][token]);

        ERC20Like(token).transfer(dst, reserve);

        emit GetReserves(msg.sender, safeHandler, token, reserve, dst);
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
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/cannot-add-more-positions"
        );

        // Fetch position details
        ( ,
          ,
          address token0_,
          address token1_,
          ,,,
        ) = positionManager.positions(tokenId);

        // Position checks
        require(token0_ != token1_, "GeneralUnderlyingMaxUniswapV3SafeSaviour/same-tokens");
        require(
          either(address(systemCoin) == token0_, address(systemCoin) == token1_),
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/not-sys-coin-pool"
        );

        // Check that the SAFE exists inside GebSafeManager
        require(safeHandler != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/safe-does-not-have-debt");

        // Update the NFT positions used to cover the SAFE and transfer the NFT to this contract
        if (lpTokenCover[safeHandler].firstId == 0) {
          lpTokenCover[safeHandler].firstId = tokenId;
        } else {
          lpTokenCover[safeHandler].secondId = tokenId;
        }

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        require(
          positionManager.ownerOf(tokenId) == address(this),
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/cannot-transfer-position"
        );

        emit Deposit(msg.sender, safeHandler, tokenId);
    }
    /*
    * @notice Withdraw lpToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside the SAFE Manager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside the SAFE Manager
    * @param tokenId The ID of the NFTed position to withdraw
    * @param dst The address that will receive the LP tokens
    */
    function withdraw(uint256 safeID, uint256 tokenId, address dst) external controlsSAFE(msg.sender, safeID) nonReentrant {
        address safeHandler = safeManager.safes(safeID);

        require(
          positionManager.ownerOf(tokenId) == address(this),
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/position-not-in-contract"
        );
        require(
          either(lpTokenCover[safeHandler].firstId == tokenId, lpTokenCover[safeHandler].secondId == tokenId),
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/cannot-add-more-positions"
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
    * @return Whether the SAFE has been saved, the amount of NTF tokens that were used to withdraw liquidity as well as the amount of
    *         system coins sent to the keeper as their payment (this implementation always returns 0)
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "GeneralUnderlyingMaxUniswapV3SafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "GeneralUnderlyingMaxUniswapV3SafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Check that the SAFE has a non null amount of NFT tokens covering it
        require(
          lpTokenCover[safeHandler].firstId != 0,
          "GeneralUnderlyingMaxUniswapV3SafeSaviour/no-cover"
        );

        // Tax the collateral
        taxCollector.taxSingle(collateralType);

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
        if (lpTokenCover[safeHandler].secondId != 0) {
          (address nonSysCoinToken, uint256 nonSysCoinBalance) =
            removeLiquidity(lpTokenCover[safeHandler].secondId);

          if (nonSysCoinBalance > 0) {
            underlyingReserves[safeHandler][nonSysCoinToken] = add(
              underlyingReserves[safeHandler][nonSysCoinToken], nonSysCoinBalance
            );
          }
        }
        {
          (address nonSysCoinToken, uint256 nonSysCoinBalance) =
            removeLiquidity(lpTokenCover[safeHandler].firstId);

          if (nonSysCoinBalance > 0) {
            underlyingReserves[safeHandler][nonSysCoinToken] = add(
              underlyingReserves[safeHandler][nonSysCoinToken], nonSysCoinBalance
            );
          }
        }

        // Get amount of sys coins withdrawn
        sysCoinBalance = sub(systemCoin.balanceOf(address(this)), sysCoinBalance);

        // Get the amounts of tokens sent to the keeper as payment
        uint256 keeperSysCoins =
          getKeeperPayoutTokens(
            safeHandler,
            sysCoinBalance
          );

        // There must be tokens that go to the keeper
        require(keeperSysCoins > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/cannot-pay-keeper");

        // Get the amount of tokens used to top up the SAFE
        uint256 safeDebtRepaid =
          getTokensForSaving(
            safeHandler,
            sub(sysCoinBalance, keeperSysCoins)
          );

        // There must be tokens used to save the SAVE
        require(safeDebtRepaid > 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/cannot-save-safe");

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance = sub(sysCoinBalance, add(safeDebtRepaid, keeperSysCoins));

        // Update system coin reserves
        if (sysCoinBalance > 0) {
          underlyingReserves[safeHandler][address(systemCoin)] = add(
            underlyingReserves[safeHandler][address(systemCoin)], sysCoinBalance
          );
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

        // Pay keeper
        systemCoin.transfer(keeper, keeperSysCoins);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, totalCover);

        return (true, totalCover, 0);
    }

    // --- Internal Logic ---
    /**
     * @notice Remove all liquidity from the positions covering a specific SAFE and
     *         return the address and amount of the non system coin token
     * @param tokenId The ID of the position from which we withdraw liquidity
     */
    function removeLiquidity(uint256 tokenId) internal returns (address, uint256) {
        // Check which token is not the system coin and fetch the current balance
        ( ,
          ,
          address token0_,
          address token1_,
          ,,,
        ) = positionManager.positions(tokenId);
        ERC20Like nonSystemCoin               = (token0_ == address(systemCoin)) ? ERC20Like(token1_) : ERC20Like(token0_);
        uint256   currentNonSystemCoinBalance = nonSystemCoin.balanceOf(address(this));

        // Approve the position to be handled by the liquidity remover
        positionManager.approve(address(liquidityRemover), tokenId);

        // Remove liquidity and fees
        liquidityRemover.removeAllLiquidity(tokenId);

        // Checks
        require(positionManager.ownerOf(tokenId) == address(this), "GeneralUnderlyingMaxUniswapV3SafeSaviour/position-not-back");

        ( ,,,,,,,
          uint128 liquidity
        ) = positionManager.positions(tokenId);
        require(liquidity == 0, "GeneralUnderlyingMaxUniswapV3SafeSaviour/invalid-liquidity-decrease");

        return (address(nonSystemCoin), sub(nonSystemCoin.balanceOf(address(this)), currentNonSystemCoinBalance));
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
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        if (safeDebt == 0) {
            return 0;
        }

        // See how many system coins can be used to save the SAFE
        uint256 usedSystemCoins;
        (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralJoin.collateralType());
        if (coinsLeft >= safeDebt) usedSystemCoins = safeDebt;
        else if (debtFloor < safeDebt) {
          usedSystemCoins = min(sub(safeDebt, debtFloor), coinsLeft);
        }

        // See if the SAFE can be saved
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralJoin.collateralType());
        bool safeSaved = (
          mul(depositedCollateralToken, liquidationPrice) <
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
    * @notify Get the accumulated interest rate for a specific collateral type as well as its current liquidation price
    * @param The collateral type for which to retrieve the rate and the price
    */
    function getAccumulatedRateAndLiquidationPrice(bytes32 collateralType)
      public view returns (uint256 accumulatedRate, uint256 liquidationPrice) {
        (, accumulatedRate, , , , liquidationPrice) = safeEngine.collateralTypes(collateralType);
    }
}
