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
import "../interfaces/UniswapV3NonFungiblePositionManagerLike.sol";
import "../interfaces/UniswapV3LiquidityRemoverLike.sol";

import {UniswapV3PoolLike} from "../integrations/uniswap/uni-v3/UniswapV3FeeCalculator.sol";

import "../math/SafeMath.sol";

contract NativeUnderlyingMaxUniswapV3SafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "NativeUnderlyingMaxUniswapV3SafeSaviour/account-not-authorized");
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
          "NativeUnderlyingMaxUniswapV3SafeSaviour/account-not-allowed"
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
    // Contract helping with liquidity removal
    UniswapV3LiquidityRemoverLike           public liquidityRemover;
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
        address oracleRelayer_,
        address safeManager_,
        address saviourRegistry_,
        address positionManager_,
        address targetUniswapPool_,
        address liquidityRemover_,
        address liquidationEngine_,
        address taxCollector_,
        address safeEngine_,
        address systemCoinOrcl_,
        uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-coin-join");
        require(collateralJoin_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-collateral-join");
        require(oracleRelayer_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-oracle-relayer");
        require(safeManager_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-saviour-registry");
        require(positionManager_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-positions-manager");
        require(targetUniswapPool_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-target-pool");
        require(liquidityRemover_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-liquidity-remover");
        require(liquidationEngine_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-liquidation-engine");
        require(taxCollector_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-tax-collector");
        require(safeEngine_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-safe-engine");
        require(systemCoinOrcl_ != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-system-coin-oracle");
        require(minKeeperPayoutValue_ > 0, "NativeUnderlyingMaxUniswapV3SafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        isSystemCoinToken0   = isSystemCoinToken0_;
        minKeeperPayoutValue = minKeeperPayoutValue_;
        targetUniswapPool    = targetUniswapPool_;

        coinJoin             = CoinJoinLike(coinJoin_);
        collateralJoin       = CollateralJoinLike(collateralJoin_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        liquidityRemover     = UniswapV3LiquidityRemoverLike(liquidityRemover_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        taxCollector         = TaxCollectorLike(taxCollector_);
        safeEngine           = SAFEEngineLike(safeEngine_);
        systemCoinOrcl       = PriceFeedLike(systemCoinOrcl_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        positionManager      = UniswapV3NonFungiblePositionManagerLike(positionManager_);
        collateralToken      = ERC20Like(collateralJoin.collateral());

        oracleRelayer.redemptionPrice();
        poolFee = UniswapV3PoolLike(targetUniswapPool).fee();

        require(poolFee > 0, "NativeUnderlyingMaxUniswapV3SafeSaviour/null-pool-fee");
        require(collateralJoin.contractEnabled() == 1, "NativeUnderlyingMaxUniswapV3SafeSaviour/join-disabled");
        require(address(collateralToken) != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-col-token");
        require(address(safeEngine) != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-sys-coin");

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
            require(val > 0, "NativeUnderlyingMaxUniswapV3SafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "NativeUnderlyingMaxUniswapV3SafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("NativeUnderlyingMaxUniswapV3SafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-data");

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
        else revert("NativeUnderlyingMaxUniswapV3SafeSaviour/modify-unrecognized-param");
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

        require(reserve > 0, "NativeUnderlyingMaxUniswapV3SafeSaviour/no-reserves");
        delete(underlyingReserves[safeHandler]);

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
          "NativeUnderlyingMaxUniswapV3SafeSaviour/cannot-add-more-positions"
        );

        // Fetch position details
        ( ,
          ,
          address token0_,
          address token1_,
          uint24 fee_,
          ,,
        ) = positionManager.positions(tokenId);

        // Position checks
        require(token0_ != token1_, "NativeUnderlyingMaxUniswapV3SafeSaviour/same-tokens");
        require(
          either(address(systemCoin) == token0_, address(systemCoin) == token1_),
          "NativeUnderlyingMaxUniswapV3SafeSaviour/not-sys-coin-pool"
        );
        require(
          either(address(collateralToken) == token0_, address(collateralToken) == token1_),
          "NativeUnderlyingMaxUniswapV3SafeSaviour/not-collateral-token-pool"
        );

        // Check that the SAFE exists inside GebSafeManager
        require(safeHandler != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        require(safeDebt > 0, "NativeUnderlyingMaxUniswapV3SafeSaviour/safe-does-not-have-debt");

        // Update the NFT positions used to cover the SAFE and transfer the NFT to this contract
        if (lpTokenCover[safeHandler].firstId == 0) {
          lpTokenCover[safeHandler].firstId = tokenId;
        } else {
          lpTokenCover[safeHandler].secondId = tokenId;
        }

        positionManager.transferFrom(msg.sender, address(this), tokenId);
        require(
          positionManager.ownerOf(tokenId) == address(this),
          "NativeUnderlyingMaxUniswapV3SafeSaviour/cannot-transfer-position"
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
          "NativeUnderlyingMaxUniswapV3SafeSaviour/position-not-in-contract"
        );
        require(
          either(lpTokenCover[safeHandler].firstId == tokenId, lpTokenCover[safeHandler].secondId == tokenId),
          "NativeUnderlyingMaxUniswapV3SafeSaviour/position-not-depostied"
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

      event log_int                (uint);

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by withdrawing liquidity and repaying debt and/or adding more collateral
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of NFT tokens that were used to withdraw liquidity as well as the amount of
    *         system coins sent to the keeper as their payment (this implementation always returns 0)
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "NativeUnderlyingMaxUniswapV3SafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "NativeUnderlyingMaxUniswapV3SafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        require(collateralType == collateralJoin.collateralType(), "NativeUnderlyingMaxUniswapV3SafeSaviour/invalid-collateral-type");

        // Check that the SAFE has a non null amount of NFT tokens covering it
        require(
          either(lpTokenCover[safeHandler].firstId != 0, underlyingReserves[safeHandler] > 0),
          "NativeUnderlyingMaxUniswapV3SafeSaviour/no-cover"
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
        if (lpTokenCover[safeHandler].secondId != 0) removeLiquidity(lpTokenCover[safeHandler].secondId);
        if (lpTokenCover[safeHandler].firstId != 0)  removeLiquidity(lpTokenCover[safeHandler].firstId);

        // Get amounts withdrawn
        sysCoinBalance = add(
          sub(systemCoin.balanceOf(address(this)), sysCoinBalance),
          underlyingReserves[safeHandler]
        );

        // Get the amounts of tokens sent to the keeper as payment
        (uint256 keeperSysCoins, uint256 keeperCollateralCoins) =
          getKeeperPayoutTokens(
            safeHandler,
            sysCoinBalance,
            collateralToken.balanceOf(address(this))
          );

        // There must be tokens that go to the keeper
        require(either(keeperSysCoins > 0, keeperCollateralCoins > 0), "NativeUnderlyingMaxUniswapV3SafeSaviour/cannot-pay-keeper");

        // Get the amount of tokens used to top up the SAFE
        (uint256 safeDebtRepaid, uint256 safeCollateralAdded) =
          getTokensForSaving(
            safeHandler,
            sub(sysCoinBalance, keeperSysCoins),
            sub(collateralToken.balanceOf(address(this)), keeperCollateralCoins)
          );

        // There must be tokens used to save the SAVE
        require(either(safeDebtRepaid > 0, safeCollateralAdded > 0), "NativeUnderlyingMaxUniswapV3SafeSaviour/cannot-save-safe");

        // Compute remaining balances of tokens that will go into reserves
        sysCoinBalance = sub(sysCoinBalance, add(safeDebtRepaid, keeperSysCoins));

        // Update reserves
        underlyingReserves[safeHandler] = sysCoinBalance;

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

        // Check the SAFE is saved
        require(safeIsAfloat(collateralType, safeHandler), "NativeUnderlyingMaxUniswapV3SafeSaviour/safe-not-saved");

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
     */
    function removeLiquidity(uint256 tokenId) internal {
         (, , , , , , , uint128 liquidity) = positionManager.positions(tokenId);

        address(positionManager).call(abi.encodeWithSelector(
          bytes4(keccak256("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))")),
          uint256(tokenId), uint128(liquidity), uint256(0), uint256(0), uint256(block.timestamp)
        ));

        address(positionManager).call(abi.encodeWithSelector(
          bytes4(keccak256("collect((uint256,address,uint128,uint128))")),
          uint256(tokenId), address(this), uint128(-1), uint128(-1)
        ));
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
    * @notify Returns whether a SAFE can be currently saved
    * @dev This implementation always return false
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
    * @notice Return the amount of system coins and/or collateral tokens used to save a SAFE
    * @param safeHandler The handler/address of the targeted SAFE
    * @param coinsLeft System coins left to save the SAFE after paying the liquidation keeper
    * @param collateralleft Collateral tokens left to save the SAFE after paying the liquidation keeper
    */
    function getTokensForSaving(
      address safeHandler,
      uint256 coinsLeft,
      uint256 collateralLeft
    ) public returns (uint256, uint256) {
        if (both(coinsLeft == 0, collateralLeft == 0)) {
            return (0, 0);
        }

        // Get the default CRatio for the SAFE
        (uint256 depositedCollateralToken, uint256 nonAdjustedSafeDebt) =
          SAFEEngineLike(collateralJoin.safeEngine()).safes(collateralJoin.collateralType(), safeHandler);
        
        if (nonAdjustedSafeDebt == 0) {
            return (0, 0);
        }

        // See if the SAFE can be saved by adding all collateral left
        (uint256 accumulatedRate, uint256 liquidationPrice) =
          getAccumulatedRateAndLiquidationPrice(collateralJoin.collateralType());

        uint256 nonAdjustedCoinsLeft = div(mul(coinsLeft, RAY), accumulatedRate);

        // Calculate how many coins can be used to save the SAFE
        uint256 nonAdjustedUsedSystemCoins;
        if (coinsLeft > 0) {
          (, , , , uint256 debtFloor, ) = safeEngine.collateralTypes(collateralJoin.collateralType()); // RAD
          
          if (nonAdjustedCoinsLeft >= nonAdjustedSafeDebt) {
            // The debt can be fully repaid by the savior
            nonAdjustedUsedSystemCoins = nonAdjustedSafeDebt;
          }
          else if (mul(nonAdjustedSafeDebt, accumulatedRate) > debtFloor) {
            // The debt is partially repaid by the saviour.
            // Make sure we don't endup below the debt floor
            nonAdjustedUsedSystemCoins =  min(sub(nonAdjustedSafeDebt, div(debtFloor, RAY)), nonAdjustedCoinsLeft);
          } else {
            // The debt is already smaller than the floor. This is an edge caused by having lowered the debt floor. Don't touch it.
            nonAdjustedUsedSystemCoins = 0;
          }
        }

        
        bool safeSaved = (
          mul(sub(nonAdjustedSafeDebt, nonAdjustedUsedSystemCoins), accumulatedRate) <= 
          mul(add(depositedCollateralToken, collateralLeft), liquidationPrice)
        );

        uint256 adjustedUsedSystemCoins =  div(mul(nonAdjustedUsedSystemCoins, accumulatedRate), RAY);

        if (safeSaved) return (adjustedUsedSystemCoins, collateralLeft);
        else {
          return (0, 0);
        }
    }
    /*
    * @notice Return the amount of system coins and/or collateral tokens used to pay a keeper
    * @param safeHandler The handler/address of the targeted SAFE
    * @param sysCoinsFromLP System coins withdrawn from Uniswap
    * @param collateralFromLP Collateral tokens withdrawn from Uniswap
    */
    function getKeeperPayoutTokens(
      address safeHandler,
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
