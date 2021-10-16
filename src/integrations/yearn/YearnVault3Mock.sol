pragma solidity >=0.6.7;

import "ds-token/token.sol";

import "../../interfaces/YVault3Like.sol";
import "../../interfaces/ERC20Like.sol";

contract YearnVault3Mock is YVault3Like, DSToken {
    // --- Variables ---
    uint256   private sharePrice;

    bool      private canTransferToken;

    ERC20Like private token;

    constructor(bool canTransferToken_, address token_, uint256 sharePrice_) public DSToken("YV", "YV") {
        canTransferToken = canTransferToken_;
        token            = ERC20Like(token_);
        sharePrice       = sharePrice_;
    }

    // --- Administration ---
    function toggleCanTransferToken() public {
        canTransferToken = !canTransferToken;
    }

    function setSharePrice(uint256 sharePrice_) public {
        sharePrice = sharePrice_;
    }

    // --- Core Logic ---
    function deposit(uint256 amount, address receiver) external override returns (uint256) {
        return 0;
    }

    function withdraw(uint256 amount, address receiver, uint256 maxLoss) external override returns (uint256) {
        if (!canTransferToken) revert();
        token.transfer(receiver, amount);
    }

    function pricePerShare() external override returns (uint256) {
        return sharePrice;
    }
}
