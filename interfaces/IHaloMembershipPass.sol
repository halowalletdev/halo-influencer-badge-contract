// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IHaloMembershipPass {
    function userMainProfile(
        address user
    ) external view returns (uint256 tokenId);

    function ownerOf(uint256 tokenId) external view returns (address);

    function levelOfToken(uint256 tokenId) external view returns (uint8 level);
}
