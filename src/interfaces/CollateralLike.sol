pragma solidity 0.6.7;

abstract contract CollateralLike {
    function decimals() virtual public view returns (uint);
    function transfer(address,uint) virtual public returns (bool);
    function transferFrom(address,address,uint) virtual public returns (bool);
}
