pragma solidity >=0.6.7;

abstract contract UniswapV3CalculatorLike {
    function positionManager() public virtual view returns (address);
    function getUncollectedFees(
       address,
       uint256
    )
       external
       virtual
       view
       returns (uint256, uint256);
}
