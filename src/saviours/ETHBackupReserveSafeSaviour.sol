pragma solidity 0.6.7;

import "./interfaces/SafeSaviourLike.sol";
import "./interfaces/CollateralJoinLike.sol";

contract ETHBackupReserveSafeSaviour is SafeSaviourLike {
    CollateralJoinLike collateralJoin;

    constructor() public {}
}
