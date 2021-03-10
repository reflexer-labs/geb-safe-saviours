pragma solidity ^0.6.7;

abstract contract LiquidationEngineLike {
    function safeSaviours(address) virtual public view returns (uint256);
}
