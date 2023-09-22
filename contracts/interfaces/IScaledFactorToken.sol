// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

interface IScaledFactorToken {
  /**
   * @dev Returns the scaled factor of the user. The scaled factor is the sum of all the
   * updated stored balance divided by the reserve's liquidity index at the moment of the update
   * @param user The user whose balance is calculated
   * @return The scaled factor of the user
   **/
  function scaledFactor(address user) external view returns (uint256);

  /**
   * @dev Returns the scaled factor of the user and the scaled total supply.
   * @param user The address of the user
   * @return The scaled factor of the user
   * @return The scaled factor and the scaled total supply
   **/
  function getUserScaledFactorAndSupply(address user) external view returns (uint256, uint256);

  /**
   * @dev Returns the scaled total supply of the variable debt token. Represents sum(debt/index)
   * @return the scaled total supply
   **/
  function scaledFactorTotalSupply() external view returns (uint256);
}