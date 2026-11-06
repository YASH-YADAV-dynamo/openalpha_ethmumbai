// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MirrorToken is ERC20 {
    address public immutable venue;
    uint8 private immutable _tokenDecimals;

    error NotVenue();
    error InvalidVenue();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address venue_)
        ERC20(name_, symbol_)
    {
        if (venue_ == address(0)) revert InvalidVenue();
        venue = venue_;
        _tokenDecimals = decimals_;
    }

    modifier onlyVenue() {
        if (msg.sender != venue) revert NotVenue();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amt) external onlyVenue {
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external onlyVenue {
        _burn(from, amt);
    }
}
