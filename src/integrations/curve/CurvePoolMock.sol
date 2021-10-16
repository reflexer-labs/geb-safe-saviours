pragma solidity >=0.6.7;

import "../../interfaces/CurveV1PoolLike.sol";
import "../../interfaces/ERC20Like.sol";

contract CurvePoolMock {
    // --- Variables ---
    address   private redemptionPriceSnap;
    ERC20Like private lpToken;

    bool      private killed;

    address[] private _coins;
    uint256[] private defaultCoinAmounts;

    constructor(uint256[] memory coinAmounts, address[] memory coins_, address _redemptionPriceSnap, address _lpToken) public {
        require(coins_.length > 0, "CurvePoolMock/null-coins");
        require(coins_.length == coinAmounts.length, "CurvePoolMock/invalid-array-lengths");

        killed              = false;

        _coins              = coins_;
        defaultCoinAmounts  = coinAmounts;
        redemptionPriceSnap = _redemptionPriceSnap;
        lpToken             = ERC20Like(_lpToken);
    }

    function coins() public view returns (address[] memory) {
        return _coins;
    }

    function redemption_price_snap() public view returns (address) {
        return redemptionPriceSnap;
    }

    function lp_token() public view returns (address) {
        return address(lpToken);
    }

    function is_killed() public view returns (bool) {
        return killed;
    }

    function remove_liquidity(uint256 _amount, uint256[] memory _min_amounts) public returns (uint256[] memory) {
        require(lpToken.transferFrom(msg.sender, address(this), _amount), "CurvePoolMock/cannot-transfer-lp-token");

        uint256 amountSent;

        for (uint i = 0; i < defaultCoinAmounts.length; i++) {
            amountSent = (_min_amounts[i] >= defaultCoinAmounts[i]) ? _min_amounts[i] : defaultCoinAmounts[i];

            ERC20Like(_coins[i]).transfer(msg.sender, amountSent);
        }
    }
}
