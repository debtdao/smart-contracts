pragma solidity ^0.8.9;

// Helpers
import { TermLoan } from "./TermLoan.sol";
import { ILoan } from "../../interfaces/ILoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";

abstract contract BulletLoan is TermLoan {
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

    if(block.timestamp - currentPaymentPeriodStart < repaymentPeriodLength) {
      return 0;
    }

    overduePaymentsAmount = _getMissedPayments();

    uint256 totalOwed;
    bool isEnd = endTime - block.timestamp <= repaymentPeriodLength;

    // must already _accrueInterest in depositAndRepay/_getMissedPayments
    totalOwed = isEnd ? 
      // loan has ended. repay all principal + interest
      terms[positionId].initialPrincipal + debts[positionId].interestAccrued + overduePaymentsAmount :
      // normal interest payment
      debts[positionId].interestAccrued + overduePaymentsAmount;

    // _get shouldn't have side effects i feel like
    if(requestedRepayAmount < totalOwed) {
      totalOwed = requestedRepayAmount;
      // if they can't make full payment then update status. if loan is ended that means they cant repay and is insolvent
      if(isEnd) {
        emit Default(positionId);
        _updateLoanStatus(LoanLib.STATUS.LIQUIDATABLE);
      } else {
        _updateLoanStatus(LoanLib.STATUS.DELINQUENT);
      }
    }

    return totalOwed;
  }

  function _getMissedPayments() virtual internal returns(uint256) {
    if(currentPaymentPeriodStart + repaymentPeriodLength > block.timestamp) {
      // haven't missed a payment this cycle. may still owe from last missed cycles
      return overduePaymentsAmount;
    }

    // sol automatically rounds down so current period isn't included
    uint256 totalPeriodsMissed = (block.timestamp - currentPaymentPeriodStart) / repaymentPeriodLength;

    DebtPosition memory debt = debts[loanPositionId];

    uint256 totalMissedPayments = overduePaymentsAmount;

    for(uint i; i <= totalPeriodsMissed; i++) {
      // update storage directly because _accrueInterest uses/updates the values
      (uint256 interestOwed, ) = _accrueInterest(loanPositionId);
      totalMissedPayments += interestOwed;
    }

    return totalMissedPayments;
  }
}
