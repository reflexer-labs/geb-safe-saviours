pragma solidity 0.6.7;

abstract contract SafeSaviourLike {
    function saveSAFE(address,bytes32,address) virtual external returns (bool,uint256,uint256);
}
