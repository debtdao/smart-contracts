pragma solidity 0.8.9;

import "forge-std/Test.sol";
import { InterestRateTerm } from "./InterestRateTerm.sol";

contract InterestRateTermTest is Test {

    uint balance;
    uint correctRepayBalance;
    InterestRateRevolver Revolver;

    function setUp() public {
        Revolver = new InterestRateTerm(1000); // 10%
        balance = 100;
        correctRepayBalance = 10;
    }

    function testRateMath() public {
        repaybalance = Revolver.accrueInterest(balance);
        assertEq(repayBalance, correctRepayBalance);
    }
}
