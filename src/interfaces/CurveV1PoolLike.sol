pragma solidity >=0.6.7;

abstract contract CurveV1PoolLike {
    function coins(uint256 index) public virtual view returns (address);
    function redemption_price_snap() public virtual view returns (address);
    function lp_token() public virtual view returns (address);
    function remove_liquidity(uint256 _amount, uint256[2] memory _min_amounts) public virtual returns (uint256[] memory);
}
