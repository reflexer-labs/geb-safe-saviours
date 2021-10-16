pragma solidity >=0.6.7;

abstract contract YVault3Like {
    function deposit(uint256, address) virtual external returns (uint256);
    function withdraw(uint256, address, uint256) virtual external returns (uint256);
    function pricePerShare() virtual external returns (uint256);
}
