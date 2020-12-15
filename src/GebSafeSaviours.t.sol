pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./GebSafeSaviours.sol";

contract GebSafeSavioursTest is DSTest {
    GebSafeSaviours saviours;

    function setUp() public {
        saviours = new GebSafeSaviours();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
