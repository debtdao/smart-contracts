
pragma solidity ^0.8.9;

import { BaseLoan } from "./BaseLoan.sol";
import { LoanLib } from "../../utils/LoanLib.sol";
import { ITermLoan } from "../../interfaces/ITermLoan.sol";
import { InterestRateTerm } from "../interest-rate/InterestRateTerm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract TermLoan is BaseLoan, ITermLoan {
  uint256 constant GRACE_PERIOD = 1 days;

  uint256 immutable repaymentPeriodLength;
  uint256 immutable totalRepaymentPeriods;

  InterestRateTerm immutable interestRate;
  
  // helper var.
  // time when loan is done
  uint256 endTime;
  
   mapping(bytes32 => TermMetadata) terms;

  // the only loan allowed on this contract. set in addDebtPosition()
  bytes32 loanPositionId;

  uint256 currentPaymentPeriodStart;
  uint256 overduePaymentsAmount;

  constructor(
    uint256 repaymentPeriodLength_,
    uint256 totalRepaymentPeriods_,
    uint256 interestRateBps
  ) {
    repaymentPeriodLength = repaymentPeriodLength_;
    totalRepaymentPeriods = totalRepaymentPeriods_;
    interestRate = new InterestRateTerm(interestRateBps);
  }

  function init() onlyBorrower external returns(bool) {
    // start loan clock
    currentPaymentPeriodStart = block.timestamp;
    endTime = block.timestamp + (repaymentPeriodLength * totalRepaymentPeriods);

    uint256 startingPrincipal = 0;
    uint256 length = positionIds.length;
    DebtPosition memory debt;
    

    for(uint256 i = 0; i < length; i++) {
      bytes32 id = positionIds[i];
      debt = debts[id];
      bool success = IERC20(debt.token).transferFrom(debt.lender, borrower, debt.deposit);
      if(!success) {
        // lender can not make payment. remove from loan
        _close(id);
      } else {
        debt.principal = debt.deposit;
        emit Borrow(id, debt.principal); // loan is automatically borrowed

        startingPrincipal += (debt.principal * _getTokenPrice(debt.token)) / (1 * 10 ** debt.decimals);

        debt.init = true;
        terms[id] = TermMetadata({
          initialPrincipal: debt.principal,
          currentPaymentPeriodStart: block.timestamp,
          overdueAmount: 0
        });
      }
    }
    
    // save global usd principal value
    principal = startingPrincipal;

    return true;
  }

  function _getInterestPaymentAmount(bytes32 positionId)
    virtual override
    internal
    returns(uint256)
  {
    // dont add interest if already charged for period
    bool isAlreadyPaid = debts[positionId].isInterestAccruedForPeriod(currentPaymentPeriodStart);
    if(isAlreadyPaid) return 0;

    uint256 outstandingdDebt = debts[positionId].principal + debts[positionId].interestAccrued;
    
    return interestRate.accrueInterest(outstandingdDebt);
  }

  function _repay(
    bytes32 positionId,
    uint256 amount
  ) override internal returns(bool) {
        // move all this logic to Revolver.sol
    DebtPosition memory debt = debts[positionId];
    TermMetadata memory term = terms[positionId];
    
    uint256 price = _getTokenPrice(debt.token);

    if(amount <= debt.interestAccrued) {
      // simple interest payment
      
      debt.interestAccrued -= amount;
      debt.interestRepaid += amount;

      // update global debt denominated in usd
      totalInterestAccrued -= price * amount / debt.decimals;
      emit RepayInterest(positionId, amount);
    } else {
      // pay off interest then any overdue payments then principal

      amount -= debt.interestAccrued;
      debt.interestRepaid += debt.interestAccrued;
      totalInterestAccrued -= price * debt.interestAccrued / 1 * 10 ** debt.decimals;

      // emit before set to 0
      emit RepayInterest(positionId, debt.interestAccrued);
      debt.interestAccrued = 0;

      if(term.overdueAmount > amount) {
        emit RepayOverdue(positionId, amount);
        term.overdueAmount -= amount;
      } else {
        // emit 
        amount -= term.overdueAmount;
        emit RepayOverdue(positionId, term.overdueAmount);
        term.overdueAmount = 0;

        debt.principal -= amount;
        principal -= price * amount / debt.decimals;
        emit RepayPrincipal(positionId, amount);
      }

      // missed payments get added to principal so missed payments + extra $ reduce principal
      debt.principal -= amount;
      principal -= price * amount ;

      emit RepayPrincipal(positionId, amount);
    }

    term.currentPaymentPeriodStart += repaymentPeriodLength + 1; // can only repay once per peridd, 

    terms[positionId] = term;
    debts[positionId] = debt;

    return true;
  }

  function _close(bytes32 positionId) virtual override internal returns(bool) {
    loanStatus = LoanLib.STATUS.REPAID; // can only close if full loan is repaid
    return super._close(positionId);
  }

  function _healthcheck() virtual override(BaseLoan) internal returns(LoanLib.STATUS) {
    // if loan was already repaid then _healthcheck isn't called so must be defaulted
    if(_isEnd() && principal > 0) {
      // if defaulted figure out which ones
      uint256 length = positionIds.length;
      for(uint256 i = 0; i < length; i++) {
        if(debts[positionIds[i]].principal > 0) emit Default(positionIds[i]);
      }
      
      return LoanLib.STATUS.LIQUIDATABLE;
    }

    // if period starts in the future bc already paid this period
    uint256 timeSinceRepayment = currentPaymentPeriodStart > block.timestamp ?
      0 :
      block.timestamp - currentPaymentPeriodStart;
    // miss 1 payment? jail
    if(timeSinceRepayment > repaymentPeriodLength + GRACE_PERIOD) {
      return LoanLib.STATUS.DELINQUENT;
    }
    // believe it or not, miss 2 payments, straight to debtor jail
    if(timeSinceRepayment > repaymentPeriodLength * 2 + GRACE_PERIOD) {
      emit Default(loanPositionId);
      return LoanLib.STATUS.LIQUIDATABLE;
    }

    if(overduePaymentsAmount > 0) {
      // they mde a recent payment but are behind on payments overalls
      return LoanLib.STATUS.DELINQUENT;
    }



    return BaseLoan._healthcheck();
  }

  /**
   * @notice returns true if is last payment period of loan or later
   * @dev 
   */
  function _isEnd() internal view returns(bool) {
    return (
      endTime > block.timestamp ||
      endTime - block.timestamp <= repaymentPeriodLength
    );
  }

}
