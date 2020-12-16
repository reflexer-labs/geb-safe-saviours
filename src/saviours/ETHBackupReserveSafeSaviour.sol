pragma solidity 0.6.7;

import "../interfaces/SafeSaviourLike.sol";

import "../math/SafeMath.sol";
import "../utils/ReentrancyGuard.sol";

contract ETHBackupReserveSafeSaviour is SafeMath, ReentrancyGuard, SafeSaviourLike {
    // --- Variables ---
    mapping(address => uint256) public depositedETH;

    // --- Constants ---
    uint256 public constant THOUSAND = 1000;

    constructor(
      address collateralJoin_,
      address liquidationEngine_,
      address oracleRelayer_,
      uint256 minKeeperPayout_,
      uint256 maxKeeperPayout_,
      uint256 maxCreatorPayout_,
      uint256 creatorRewardPercentage_,
      uint256 keeperRewardPercentage_
    ) public {
        require(collateralJoin_ != address(0), "ETHBackupReserveSafeSaviour/null-collateral-join");
        require(liquidationEngine_ != address(0), "ETHBackupReserveSafeSaviour/null-liquidation-engine");
        require(oracleRelayer_ != address(0), "ETHBackupReserveSafeSaviour/null-oracle-relayer");
        require(minKeeperPayout_ > 0, "ETHBackupReserveSafeSaviour/invalid-min-keeper-payout");
        require(minKeeperPayout_ <= maxKeeperPayout_, "ETHBackupReserveSafeSaviour/invalid-max-keeper-payout");
        require(creatorRewardPercentage_ < THOUSAND, "ETHBackupReserveSafeSaviour/invalid-creator-reward");
        require(both(keeperRewardPercentage_ > 0, keeperRewardPercentage_ < THOUSAND), "ETHBackupReserveSafeSaviour/invalid-keeper-reward");
        require(add(creatorRewardPercentage_, keeperRewardPercentage_) < THOUSAND, "ETHBackupReserveSafeSaviour/rewards-exceed-max-possible");

        minKeeperPayout         = minKeeperPayout_;
        maxKeeperPayout         = maxKeeperPayout_;
        creatorRewardPercentage = creatorRewardPercentage_;
        keeperRewardPercentage  = keeperRewardPercentage_;

        liquidationEngine       = LiquidationEngineLike(liquidationEngine_);
        collateralJoin          = CollateralJoinLike(collateralJoin_);
        oracleRelayer           = OracleRelayerLike(oracleRelayer_);

        require(oracleRelayer.liquidationCRatio(collateralJoin.collateralType()) > 0, "ETHBackupReserveSafeSaviour/invalid-liquidation-c-ratio");
        require(collateralJoin.decimals() == 18, "ETHBackupReserveSafeSaviour/invalid-join-decimals");
        require(collateralJoin.contractEnabled() == 1, "ETHBackupReserveSafeSaviour/join-disabled");
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y) }
    }

    // --- Adding Cover ---
    function depositETHAndCoverSafe(address safeHandler, uint256 wethAmount) external payable nonReentrant liquidationEngineApproved(address(this)) {

    }
    function withdrawETHAndUncoverSafe(address safeHandler, uint256 wethAmount) external nonReentrant {

    }

    // --- Saving Logic ---
    function saveSAFE(address liquidator, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "ETHBackupReserveSafeSaviour/caller-not-liquidation-engine");

    }
    function canSave(address safeHandler) override external returns (bool) {

    }
}
