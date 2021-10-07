pragma solidity 0.6.7;

abstract contract YVaultLike {
    function deposit(uint256) virtual external returns (uint256);
    function withdraw(uint256) virtual external returns (uint256);
    function balanceOf(address) virtual external returns (uint256);
    function pricePerShare() virtual external returns (uint256);
}
