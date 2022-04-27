pragma solidity 0.8.9;

import "forge-std/Test.sol";
import { InterestRateRevolver } from "./InterestRateRevolver.sol";

contract InterestRateRevolverTest is Test {

    uint drawnBalance;
    uint facilityBalance;
    uint correctRepayBalance;
    InterestRateRevolver Revolver;

    function setUp() public {
        Revolver = new InterestRateRevolver(500, 1000); // 5% and 10%
        drawnBalance = 100;
        facilityBalance = 500;
        correctRepayBalance = 55;
    }

    function testRateMath() public {
        repaybalance = Revolver.accrueInterest(drawnBalance, facilityBalance);
        assertEq(repayBalance, correctRepayBalance);
    }
}
