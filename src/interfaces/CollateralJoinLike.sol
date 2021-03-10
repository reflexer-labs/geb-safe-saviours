pragma solidity ^0.6.7;

abstract contract CollateralJoinLike {
    function safeEngine() virtual public view returns (address);
    function collateralType() virtual public view returns (bytes32);
    function collateral() virtual public view returns (address);
    function decimals() virtual public view returns (uint256);
    function contractEnabled() virtual public view returns (uint256);
    function join(address, uint256) virtual external;
}
