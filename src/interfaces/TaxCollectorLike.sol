pragma solidity >=0.6.7;

abstract contract TaxCollectorLike {
    function taxSingle(bytes32) public virtual returns (uint256);
}
