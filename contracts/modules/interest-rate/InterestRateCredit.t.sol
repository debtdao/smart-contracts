
pragma solidity ^0.8.9;

import { DSTest } from  "../../../lib/ds-test/src/test.sol";

import { InterestRateCredit } from  "./InterestRateCredit.sol";

/**
 * @notice
 * @dev - does not test spigot integration e.g. claimEscrow() since that should already be covered in Spigot tests
 *      - these tests would fail if that assumption was wrong anyway
 */
contract SpigotedLoanTest is DSTest {
    InterestRateCredit i;

    function setUp() public {
      i = new InterestRateCredit();
    }

    function test_can_add_different_rates() public {
      i.updateRate(bytes32(""), uint128(0), uint128(0));
      i.updateRate(bytes32("1"), uint128(1), uint128(1));
    }

    function test_can_accrue_interest_all_drawn() public {
      i.updateRate(bytes32(""), uint128(0), uint128(0));
      uint accrued = i.accrueInterest(bytes32(0), 1, 1);
      assertEq(accrued, 0); // TODO: figure out how to fast forward blocks in hevm to test real amounts
    }


    function test_can_accrue_interest_half_drawn() public {
      i.updateRate(bytes32(""), uint128(0), uint128(0));
      uint accrued = i.accrueInterest(bytes32(0), 1, 2);
      assertEq(accrued, 0); // TODO: figure out how to fast forward blocks in hevm to test real amounts
    }


    function test_can_accrue_interest_none_drawn() public {
      i.updateRate(bytes32(""), uint128(0), uint128(0));
      uint accrued = i.accrueInterest(bytes32(0), 0, 1);
      assertEq(accrued, 0); // TODO: figure out how to fast forward blocks in hevm to test real amounts
    }
}
