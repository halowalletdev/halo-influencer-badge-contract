// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface EventsAndErrors {
    /*//////////////////////////////////////////////////////////////
                                 events
    //////////////////////////////////////////////////////////////*/

    event CreateBadgePool(address indexed kol, uint256 indexed poolId);
    event Buy(
        uint256 indexed poolId,
        address user,
        uint256 indexed buyAmount,
        uint256 indexed allCost, //=buyPrice+protocolFee+kolFee
        uint256 buyPrice,
        uint256 protocolFee,
        uint256 kolFee,
        uint256 poolNewBalance
    );

    event Sell(
        uint256 indexed poolId,
        address user,
        uint256 indexed sellAmount,
        uint256 indexed allGain, //=sellPrice-(protocolFee+kolFee)
        uint256 sellPrice,
        uint256 protocolFee,
        uint256 kolFee,
        uint256 poolNewBalance
    );
    event AddBonus(
        address funder,
        uint256 indexed poolId,
        uint256 indexed bonusAmount,
        uint256 poolNewBalance
    );

    /*//////////////////////////////////////////////////////////////
                                 errors
    //////////////////////////////////////////////////////////////*/
}
