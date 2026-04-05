// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AZXBTC is ERC20, Ownable {

    uint256 public constant MAX_SUPPLY = 21_000_000 * 1e18;

    uint256 public taxRate = 2;
    address public treasury;
    address public stakingPool;

    mapping(address => bool) public isExempt;

    constructor(address _treasury) 
        ERC20("AZXBTC", "AZXBTC") 
        Ownable(msg.sender) 
    {
        require(_treasury != address(0), "Invalid treasury");

        treasury = _treasury;

        _mint(msg.sender, MAX_SUPPLY);

        isExempt[msg.sender] = true;
        isExempt[address(this)] = true;
    }

    function setStakingPool(address _staking) external onlyOwner {
        stakingPool = _staking;
    }

    function setTax(uint256 _tax) external onlyOwner {
        require(_tax <= 5, "Max 5%");
        taxRate = _tax;
    }

    function setExempt(address account, bool status) external onlyOwner {
        isExempt[account] = status;
    }

    function _update(address from, address to, uint256 amount) internal override {

        if (from == address(0) || to == address(0) || isExempt[from] || isExempt[to]) {
            super._update(from, to, amount);
            return;
        }

        uint256 tax = (amount * taxRate) / 100;
        uint256 sendAmount = amount - tax;

        uint256 treasuryPart = tax / 2;
        uint256 stakingPart = tax - treasuryPart;

        super._update(from, treasury, treasuryPart);

        if (stakingPool != address(0)) {
            super._update(from, stakingPool, stakingPart);
        } else {
            super._update(from, treasury, stakingPart);
        }

        super._update(from, to, sendAmount);
    }
}
