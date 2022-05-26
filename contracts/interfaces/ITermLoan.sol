interface ITermLoan {
  struct TermMetadata {
    uint256 initialPrincipal; // principal in token for compounding interest or amoratization
    uint256 currentPaymentPeriodStart;
    uint256 overdueAmount;    // in tokens
    // track if interest has already been calculated for this payment period since _accrueInterest is called in multiple places
    mapping(uint256 => bool) isInterestAccruedForPeriod; // paymemnt period timestamp -> has interest accrued
  }

  event RepayOverdue(bytes32 indexed positionId, uint256 indexed amount);
}
