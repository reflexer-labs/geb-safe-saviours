pragma solidity 0.6.7;

import "./ERC20Like.sol";

abstract contract IWETH9 is ERC20Like {
    function deposit() virtual external payable;
    function withdraw(uint256) virtual external;
}
