pragma solidity 0.6.7;

abstract contract CTokenLike {
    function mint(uint256) virtual external returns (uint256);
    function exchangeRateStored() virtual public view returns (uint);
    function exchangeRateCurrent() virtual external returns (uint256);
    function redeem(uint256) virtual external returns (uint256);
    function redeemUnderlying(uint256) virtual external returns (uint256);
    function isCToken() virtual external returns (bool);
    function balanceOfUnderlying(address) virtual external returns (uint);
    function balanceOf(address) virtual external returns (uint256);
    function approve(address, uint256) virtual external returns (bool);
}
