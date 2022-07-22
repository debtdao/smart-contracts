pragma solidity ^0.8.9;

import { IInterestRateCredit } from "../../interfaces/IInterestRateCredit.sol";


contract InterestRateCredit is IInterestRateCredit {
    uint256 constant ONE_YEAR = 364.25 days; // one year in sec to use in calculations for rates
    uint256 constant BASE_DENOMINATOR = 10000; // div 100 for %, div 100 for bps in numerator
    uint256 constant INTEREST_DENOMINATOR = ONE_YEAR * BASE_DENOMINATOR;

    address immutable loanContract;
    mapping(bytes32 => Rate) public rates; // positionId -> lending rates

    

    /**
      * @notice Interest contract for line of credit contracts
     */
    constructor () {
      loanContract = msg.sender;
    }

    ///////////  MODIFIERS  ///////////

    modifier onlyLoanContract () {
      require(msg.sender == loanContract, "InterestRateCred: only loan contract.");
      _;
    }

    ///////////  FUNCTIONS  ///////////

    /**
      * @dev accrueInterest function for revolver loan
      * @dev    - callable by `loan`
      * @param drawnBalance balance of drawn funds
      * @param facilityBalance balance of facility funds
      * @return repayBalance amount to be repaid for this interest period
      * 
    */
    function accrueInterest(
      bytes32 positionId,
      uint256 drawnBalance,
      uint256 facilityBalance
    )
      onlyLoanContract
      external
      override
      returns (uint256)
    {
      return _accrueInterest(positionId, drawnBalance, facilityBalance);
    }

    function _accrueInterest(
      bytes32 positionId,
      uint256 drawnBalance,
      uint256 facilityBalance
    )
      internal
      returns (uint256)
    {
      Rate memory rate = rates[positionId];
      uint256 timespan = block.timestamp - rate.lastAccrued;
      rates[positionId].lastAccrued = block.timestamp;

      // r = APR in BPS, x = # tokens, t = time
      // interest = (r * x * t) / 1yr / 100 
      // facility = deposited - drawn (aka undrawn balance)
      return (
        (
          (rate.drawnRate * drawnBalance * timespan)
          / INTEREST_DENOMINATOR
        ) + 
        (
          (rate.facilityRate * (facilityBalance- drawnBalance) * timespan)
          /  INTEREST_DENOMINATOR
        )
      );
    }


    /**
     * @notice update interest rates for a position
     * @dev - Loan contract responsible for calling accrueInterest() before updateInterest() if necessary
     * @dev    - callable by `loan`
     */
    function setRate(
      bytes32 positionId,
      uint128 drawnRate,
      uint128 facilityRate
    )
      onlyLoanContract
      external
      returns(bool)
    {
      rates[positionId] = Rate({
        drawnRate: drawnRate,
        facilityRate: facilityRate,
        lastAccrued: block.timestamp
      });

      return true;
    }
}
