// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20WithDecimals is IERC20 {
    // the return type for most erc20s is uint8
    // in order to be compatible with special cases, there use uint256
    function decimals() external view returns (uint256);
}
