pragma solidity ^0.6.7;

abstract contract PriceFeedLike {
    function priceSource() virtual public view returns (address);
    function getResultWithValidity() virtual external view returns (uint256,bool);
}
