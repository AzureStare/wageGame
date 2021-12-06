// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

interface IBoss {

  // struct to store each token's traits
  struct EmployeeBoss {
    bool isEmployee;
    uint8 fur;
    uint8 head;
    uint8 ears;
    uint8 eyes;
    uint8 bg;
    uint8 mouth;
    uint8 neck;
    uint8 cloth;
    uint8 alphaIndex;
  }


  function getPaidTokens() external view returns (uint256);
  function getTokenTraits(uint256 tokenId) external view returns (EmployeeBoss memory);
}