pragma solidity >=0.6.7;

import "../../interfaces/CurveV1PoolLike.sol";
import "../../interfaces/ERC20Like.sol";

contract CurvePoolMock {
    // --- Variables ---
    ERC20Like private lpToken;

    bool      private killed;
    bool      private sendFewTokens;

    address[] private _coins;
    uint256[] private defaultCoinAmounts;

    constructor(uint256[] memory coinAmounts, address[] memory coins_, address _lpToken) public {
        require(coins_.length > 0, "CurvePoolMock/null-coins");
        require(coins_.length == coinAmounts.length, "CurvePoolMock/invalid-array-lengths");

        killed              = false;

        _coins              = coins_;
        defaultCoinAmounts  = coinAmounts;
        lpToken             = ERC20Like(_lpToken);
    }

    function toggleSendFewTokens() public {
        sendFewTokens = !sendFewTokens;
    }

    function coins(uint256 index) public view returns (address) {
        return _coins[index];
    }

    function redemption_price_snap() public view returns (address) {
        return address(0x987654321);
    }

    function lp_token() public view returns (address) {
        return address(lpToken);
    }

    function remove_liquidity(uint256 _amount, uint256[2] memory _min_amounts) public returns (uint256[] memory) {
        require(lpToken.transferFrom(msg.sender, address(this), _amount), "CurvePoolMock/cannot-transfer-lp-token");

        uint256 amountSent;

        for (uint i = 0; i < defaultCoinAmounts.length; i++) {
            amountSent = (_min_amounts[i] >= defaultCoinAmounts[i]) ? _min_amounts[i] : defaultCoinAmounts[i];
            amountSent = (sendFewTokens) ? 1 : amountSent;
            ERC20Like(_coins[i]).transfer(msg.sender, amountSent);
        }
    }
}
