pragma solidity ^0.8.9;

// Helpers
import { TermLoan } from "./TermLoan.sol";
import { ILoan } from "../../interfaces/ILoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";

abstract contract AmoritizedLoan is TermLoan {

  constructor(
    uint256 repaymentPeriodLength_,
    uint256 totalRepaymentPeriods_,
    uint256 interestRateBps

  )
    TermLoan(repaymentPeriodLength_, totalRepaymentPeriods, interestRateBps)
  {
  
  }

  function _getMaxRepayableAmount(bytes32 positionId, uint256 requestedRepayAmount)
    virtual override
    internal
    returns(uint256) {

    // can repay for a period early. then currentPaymentPeriodStart is set to the end of the period so can't pay until next period
    if(block.timestamp < currentPaymentPeriodStart) {
      return 0;
    }

    overduePaymentsAmount = _getMissedPayments(positionId);

    uint256 totalOwed;
    bool isEnd = endTime - block.timestamp <= repaymentPeriodLength;

    // must already _accrueInterest in depositAndRepay/_getMissedPayments
    totalOwed = (terms[positionId].initialPrincipal / totalRepaymentPeriods) +
      debts[loanPositionId].interestAccrued +
      overduePaymentsAmount;


    // _get shouldn't have side effects i feel like
    if(requestedRepayAmount < totalOwed) {
      totalOwed = requestedRepayAmount;
      // if they can't make full payment then update status. if loan is ended that means they cant repay and is insolvent
    }

    return totalOwed;
  }

  function _getMissedPayments(bytes32 positionId) virtual internal returns(uint256) {
    if(currentPaymentPeriodStart + repaymentPeriodLength > block.timestamp) {
      // haven't missed a payment this cycle. may still owe from last missed cycles
      return overduePaymentsAmount;
    }

    // sol automatically rounds down so current period isn't included
    uint256 totalPeriodsMissed = (block.timestamp - currentPaymentPeriodStart) / repaymentPeriodLength;

    DebtPosition memory debt = debts[positionId];

    uint256 totalMissedPayments = overduePaymentsAmount;


    for(uint i; i <= totalPeriodsMissed; i++) {
      // update storage directly because _accrueInterest uses/updates the values
      (uint256 interestOwed, ) = _accrueInterest(loanPositionId);
      totalMissedPayments += interestOwed + (terms[positionId].initialPrincipal / totalRepaymentPeriods);
    }

    return totalMissedPayments;
  }
}
