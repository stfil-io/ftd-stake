// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC20Upgradeable} from "../dependencies/openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IStakedFTD is IERC20Upgradeable {
  function stake(address to, uint256 amount) external;

  function redeem(address to, uint256 amount) external;

  function cooldown() external;

  function claimRewards(address to, uint256 amount) external;
}
