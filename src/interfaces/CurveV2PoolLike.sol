pragma solidity >=0.6.7;

abstract contract CurveV2PoolLike {
    function coins(uint256 index) public virtual view returns (address);
    function token() public virtual view returns (address);
    function remove_liquidity(uint256 _amount, uint256[2] memory _min_amounts) public virtual;
    function remove_liquidity(uint256 _amount, uint256[3] memory _min_amounts) public virtual;
    function remove_liquidity(uint256 _amount, uint256[4] memory _min_amounts) public virtual;
}
