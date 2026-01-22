// SPDX-License-Identifier: LGPL-3.0
pragma solidity 0.8.30;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Errors} from './Errors.sol';

/**
 * @title Silo
 * @notice The Silo allows to store USDme during the stake cooldown process.
 */
contract Silo {
  address public immutable STAKING_VAULT;
  IERC20 public immutable USDme;

  using SafeERC20 for IERC20;

  constructor(address stakingVault, address usdme) {
    STAKING_VAULT = stakingVault;
    USDme = IERC20(usdme);
  }

  modifier onlyStakingVault() {
    require(msg.sender == STAKING_VAULT, Errors.ONLY_STAKING_VAULT);
    _;
  }

  function withdraw(address to, uint256 amount) external onlyStakingVault {
    USDme.transfer(to, amount);
  }
}