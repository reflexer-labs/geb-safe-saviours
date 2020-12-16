pragma solidity 0.6.7;

abstract contract OracleRelayerLike {
    function liquidationCRatio(bytes32) virtual public view returns (uint256);
}
