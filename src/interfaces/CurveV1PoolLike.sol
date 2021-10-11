pragma solidity >=0.6.7;

abstract contract CurveV1PoolLike {
    function coins() public virtual view returns (address[] memory);
    function redemption_price_snap() public virtual view returns (address);
    function lp_token() public virtual view returns (address);
    function is_killed() public virtual view returns (bool);
    function remove_liquidity(uint256 _amount, uint256[] memory _min_amounts) public virtual view returns (uint256[] memory);
}