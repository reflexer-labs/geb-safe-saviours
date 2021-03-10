pragma solidity ^0.6.7;

abstract contract SAFESaviourRegistryLike {
    function markSave(bytes32 collateralType, address safeHandler) virtual external;
}
