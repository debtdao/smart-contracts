import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { LoanLib } from "../../utils/LoanLib.sol";
import { MutualUpgrade } from "../../utils/MutualUpgrade.sol";
import { InterestRateCredit } from "../interest-rate/InterestRateCredit.sol";


import { IOracle } from "../../interfaces/IOracle.sol";
import { ILineOfCredit } from "../../interfaces/ILineOfCredit.sol";

contract LineOfCredit is ILineOfCredit, MutualUpgrade {
  address immutable public borrower;
  
  address immutable public arbiter;
  
  IOracle immutable public oracle; 
  
  InterestRateCredit immutable public interestRate;
  
  uint256 immutable public deadline;
  
  bytes32[] public positionIds; // all active positions

  mapping(bytes32 => DebtPosition) public debts; // positionId -> DebtPosition



  // Loan Financials aggregated accross all existing  DebtPositions
  LoanLib.STATUS public loanStatus;

  uint256 public principalUsd;  // initial principal
  uint256 public interestUsd;   // unpaid interest

  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param ttl_ - time to live for line of credit contract across all lenders
  */
  constructor(
    address oracle_,
    address arbiter_,
    address borrower_,
    uint256 ttl_
  ) {
    interestRate = new InterestRateCredit();
    deadline = block.timestamp + ttl_;
    
    loanStatus = LoanLib.STATUS.ACTIVE;

    emit DeployLoan(
      oracle_,
      arbiter_,
      borrower_
    );
  }

  ///////////////
  // MODIFIERS //
  ///////////////

  modifier isActive() {
    require(loanStatus == LoanLib.STATUS.ACTIVE, 'Loan: no op');
    _;
  }

  modifier whileBorrowing() {
    require(positionIds.length > 0 && debts[positionIds[0]].principal > 0);
    _;
  }

  modifier onlyBorrower() {
    require(msg.sender == borrower, 'Loan: only borrower');
    _;
  }

  modifier onlyArbiter() {
    require(msg.sender == arbiter, 'Loan: only arbiter');
    _;
  }


  function healthcheck() external returns(LoanLib.STATUS) {
    return _updateLoanStatus(_healthcheck());
  }

  function _healthcheck() internal virtual override returns(LoanLib.STATUS) {
    // if loan is in a final end state then do not run _healthcheck()
    if(loanStatus == LoanLib.STATUS.REPAID || loanStatus == LoanLib.STATUS.INSOLVENT) {
      return loanStatus;
    }

    // Liquidate if all lines of credit arent closed by end of term
    if(block.timestamp >= deadline && positionIds.length > 0) {
      uint256 len =  positionIds.length;
      for(uint256 i = 0; i < len; i++) {
        bytes32 id = positionIds[i];
        uint256 amount = debts[id].principal + debts[id].interestAccrued;
        uint256 val = LoanLib.getValuation(oracle, debts[id].token, amount, debts[id].decimals);
        emit Default(id, amount, val);
      }
      return LoanLib.STATUS.LIQUIDATABLE;
    }

    return LoanLib.STATUS.ACTIVE;
  }

/**
  * @notice - Returns total debt obligation of borrower.
              Aggregated across all lenders.
              Denominated in USD 1e8.
  * @dev    - callable by anyone
  */
  function getOutstandingDebt() override external returns(uint256) {
    (uint p, uint i) = _updateOutstandingDebt();
    return p + i;
  }

  function _updateOutstandingDebt()
    internal
    returns (uint principal, uint interest)
  {
    uint len = positionIds.length;
    if(len == 0) return (0,0);

    DebtPosition memory debt;
    for(uint i = 0; i < len; i++) {
      debt = debts[positionIds[len]];

      int price = oracle.getLatestAnswer(debt.token);

      principal += LoanLib.calculateValue(price, debt.principal, debt.decimals);
      interest += LoanLib.calculateValue(price, debt.interestAccrued, debt.decimals);
    }

    principalUsd = principal;
    interestUsd = interest;
  }


  /**
    * @notice - see _accrueInterest()
    * @dev    - callable by anyone
  */
  function accrueInterest() override external returns(uint256 accruedValue) {
    uint256 len = positionIds.length;

    for(uint256 i = 0; i < len; i++) {
      (, uint256 accruedTokenValue) = _accrueInterest(positionIds[i]);
      accruedValue += accruedTokenValue;
    }
  }

  /**
   * @notice - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
            Lender and borrower must both call function for MutualUpgrade to add debt position to Loan
   * @dev    - callable by `lender` and `borrower
   * @param amount - amount of `token` to initially deposit
   * @param token - the token to be lent out
   * @param lender - address that will manage debt position 
  */
  function addDebtPosition(
    uint128 drawnRate,
    uint128 facilityRate,
    uint256 amount,
    address token,
    address lender
  )
    isActive
    mutualUpgrade(lender, borrower) 
    virtual
    override
    external
    returns(bytes32)
  {
    bool success = IERC20(token).transferFrom(
      lender,
      address(this),
      amount
    );
    require(success, 'Loan: no tokens to lend');

    bytes32 id = _createDebtPosition(lender, token, amount, 0);

    require(interestRate.setRate(id, drawnRate, facilityRate));
    emit SetRates(id, drawnRate, facilityRate);

    return id;
  }

  ///////////////
  // REPAYMENT //
  ///////////////

  /**
   * @notice - Transfers enough tokens to repay entire debt position from `borrower` to Loan contract.
   * @dev - callable by borrower
            
  */
  function depositAndClose()
    whileBorrowing
    onlyBorrower
    override external
    returns(bool)
  {
    bytes32 id = positionIds[0];
    _accrueInterest(id);

    uint256 totalOwed = debts[id].principal + debts[id].interestAccrued;

    // borrower deposits remaining balance not already repaid and held in contract
    bool success = IERC20(debts[id].token).transferFrom(
      msg.sender,
      address(this),
      totalOwed
    );
    require(success, 'Loan: deposit failed');
    // clear the debt 
    _repay(id, totalOwed);

    require(_close(id));
    return true;
  }

  /**
   * @dev - Transfers token used in debt position from msg.sender to Loan contract.
   * @dev - callable by anyone
   * @notice - see _repay() for more details
   * @param amount - amount of `token` in `positionId` to pay back
  */

  function depositAndRepay(uint256 amount)
    whileBorrowing
    override
    external
    returns(bool)
  {
    bytes32 id = positionIds[0];
    _accrueInterest(id);

    require(amount <= debts[id].principal + debts[id].interestAccrued);
    
    bool success = IERC20(debts[id].token).transferFrom(
      msg.sender,
      address(this),
      amount
    );
    require(success, 'Loan: failed repayment');

    _repay(id, amount);
    return true;
  }



  ////////////////////
  // FUND TRANSFERS //
  ////////////////////


  /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
    * @dev - callable by lender on `positionId`
   * @param positionId - the debt position to draw down debt on
   * @param amount - amount of tokens borrower wants to take out
  */
  function borrow(bytes32 positionId, uint256 amount)
    isActive
    onlyBorrower
    override
    external
    returns(bool)
  {
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <= debt.deposit - debt.principal, 'Loan: no liquidity');

    debt.principal += amount;

    uint value = LoanLib.getValuation(oracle, debt.token, amount, debt.decimals);
    principalUsd += value;

    debts[positionId] = debt;

    require(
      _updateLoanStatus(_healthcheck()) == LoanLib.STATUS.ACTIVE,
      'Loan: cant borrow'
    );

    bool success = IERC20(debt.token).transfer(
      borrower,
      amount
    );
    require(success, 'Loan: borrow failed');

    emit Borrow(positionId, amount, value);

    require(_sortIntoQ(positionId));

    return true;
  }



  /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @dev - callable by lender on `positionId`
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function withdraw(bytes32 positionId, uint256 amount) override external returns(bool) {
    require(msg.sender == debts[positionId].lender, "Loan: only lender can withdraw");
    
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <=  debt.deposit + debt.interestRepaid - debt.principal, 'Loan: no liquidity');

    if(amount > debt.interestRepaid) {
      amount -= debt.interestRepaid;

      // emit events before seeting to 0
      emit WithdrawDeposit(positionId, amount);
      emit WithdrawProfit(positionId, debt.interestRepaid);

      debt.deposit -= amount;
      debt.interestRepaid = 0;
    } else {
      debt.interestRepaid -= amount;
      emit WithdrawProfit(positionId, amount);
    }

    bool success = IERC20(debt.token).transfer(
      debt.lender,
      amount
    );
    require(success, 'Loan: withdraw failed');

    debts[positionId] = debt;

    return true;
  }

  function withdrawInterest(bytes32 positionId) override external returns(uint256) {
    require(msg.sender == debts[positionId].lender, "Loan: only lender can withdraw");
    
    _accrueInterest(positionId);

    uint256 amount = debts[positionId].interestAccrued();

    bool success = IERC20(debts[positionId].token).transfer(
      debts[positionId].lender,
      amount
    );
    require(success, 'Loan: withdraw failed');

    emit WithdrawProfit(positionId, amount);
    
    return amount;
  }


  /**
   * @dev - Deletes debt position preventing any more borrowing.
   *      - Only callable by borrower or lender for debt position
   *      - Requires that the debt has already been paid off
   * @dev - callable by `borrower`
   * @param positionId -the debt position to close
  */
  function close(bytes32 positionId) override external returns(bool) {
    DebtPosition memory debt = debts[positionId];
    require(
      msg.sender == debt.lender ||
      msg.sender == borrower,
      "Loan: msg.sender must be the lender or borrower"
    );
    
    // return the lender's deposit
    if(debt.deposit > 0) {
      require(IERC20(debt.token).transfer(debt.lender, debt.deposit + debt.interestRepaid));
    }

    require(_close(positionId));
    
    return true;
  }


  //////////////////////
  //  Internal  funcs //
  //////////////////////

  function _updateLoanStatus(LoanLib.STATUS status) internal returns(LoanLib.STATUS) {
    if(loanStatus == status) return loanStatus;
    loanStatus = status;
    emit UpdateLoanStatus(uint256(status));
    return status;
  }



    function _createDebtPosition(
    address lender,
    address token,
    uint256 amount,
    uint256 initialPrincipal
  )
    internal
    returns(bytes32 positionId)
  {
    require(oracle.getLatestAnswer(token) > 0, "Loan: token cannot be valued");
    positionId = LoanLib.computePositionId(address(this), lender, token);
    
    // MUST not double add position. otherwise we can not _close()
    require(debts[positionId].lender == address(0), 'Loan: position exists');

    (bool passed, bytes memory result) = token.call(abi.encodeWithSignature("decimals()"));
    uint8 decimals = !passed ? 18 : abi.decode(result, (uint8));

    debts[positionId] = DebtPosition({
      lender: lender,
      token: token,
      decimals: decimals,
      deposit: amount,
      principal: initialPrincipal,
      interestAccrued: 0,
      interestRepaid: 0
    });

    positionIds.push(positionId); // add lender to end of repayment queue


    emit AddDebtPosition(lender, token, amount, 0);

    return positionId;
  }


   /**
   * @dev - Reduces `principal` and/or `interestAccrued` on debt position, increases lender's `deposit`.
            Reduces global USD principal and interestUsd values.
            Expects checks for conditions of repaying and param sanitizing before calling
            e.g. early repayment of principal, tokens have actually been paid by borrower, etc.
   * @param positionId - debt position struct with all data pertaining to loan
   * @param amount - amount of token being repaid on debt position
  */
  function _repay(
    bytes32 positionId,
    uint256 amount
  )
    internal
    returns(bool)
  {
    DebtPosition memory debt = debts[positionId];
    
    if(amount <= debt.interestAccrued) {
      debt.interestAccrued -= amount;
      uint val = LoanLib.getValuation(oracle, debt.token, amount, debt.decimals);
      interestUsd -= val;

      debt.interestRepaid += amount;
      emit RepayInterest(positionId, amount, val);
    } else {
      uint256 principalPayment = amount - debt.interestAccrued;

      uint iVal = LoanLib.getValuation(oracle, debt.token, debt.interestAccrued, debt.decimals);
      uint pVal = LoanLib.getValuation(oracle, debt.token, principalPayment, debt.decimals);

      emit RepayInterest(positionId, debt.interestAccrued, iVal);
      emit RepayPrincipal(positionId, principalPayment, pVal);

      // update global debt denominated in usd
      interestUsd -= iVal;
      principalUsd -= pVal;

      // update individual debt position denominated in token
      debt.principal -= principalPayment;
      debt.interestRepaid += debt.interestAccrued;
      debt.interestAccrued = 0;

      // if debt fully repaid then remove lender from repayment queue
      if(debt.principal == 0) positionIds = LoanLib.stepQ(positionIds);
    }

    debts[positionId] = debt;

    return true;
  }


  /**
   * @dev - Loops over all debt positions, calls InterestRate module with position data,
            then updates `interestAccrued` on position with returned data.
            Also updates global USD values for `interestUsd`.
            Can only be called when loan is not in distress
  */
  function _accrueInterest(bytes32 positionId)
    internal
    returns (uint256 accruedToken, uint256 accruedValue)
  {
    DebtPosition memory debt = debts[positionId];
    // get token demoninated interest accrued
    accruedToken = interestRate.accrueInterest(
      positionId,
      debt.principal,
      debt.deposit
    );

    // update debts balance
    debt.interestAccrued += accruedToken;

    // get USD value of interest accrued
    accruedValue = LoanLib.getValuation(oracle, debt.token, accruedToken, debt.decimals);
    interestUsd += accruedValue;

    emit InterestAccrued(positionId, accruedToken, accruedValue);

    debts[positionId] = debt; // save updates to intterestAccrued

    return (accruedToken, accruedValue);
  }

  /**
   * @notice - checks that debt is fully repaid and remvoes from available lines of credit.
   * @dev deletes Debt storage. Store any data u might need later in call before _close()
  */
  function _close(bytes32 positionId) virtual internal returns(bool) {
    require(
      debts[positionId].principal + debts[positionId].interestAccrued == 0,
      'Loan: close failed. debt owed'
    );

    delete debts[positionId]; // yay gas refunds!!!

    // remove from active list
    positionIds = LoanLib.removePosition(positionIds, positionId);

    // brick loan contract if all positions closed
    if(positionIds.length == 0) {
      loanStatus = LoanLib.STATUS.REPAID;
    }

    emit CloseDebtPosition(positionId);    

    return true;
  }

    /**
     * @notice - Insert `p` into the next availble FIFO position in repayment queue
               - once earliest slot is found, swap places with `p` and position in slot.
     * @param p - position id that we are trying to find appropriate place for
     * @return
     */
    function _sortIntoQ(bytes32 p) internal returns(bool) {
      uint len = positionIds.length;
      uint256 _i = 0; // index that p should be moved to

      for(uint i = 0; i < len; i++) {
        bytes32 id = positionIds[i];
        if(p != id) {
          if(debts[id].principal > 0) continue; // `id` should be placed before `p`
          _i = i; // index of first undrawn LoC found
        } else {
          if(_i == 0) return true; // `p` in earliest possible index
          // swap positions
          positionIds[i] = positionIds[_i];
          positionIds[_i] = p;
        }
    }

    return true;
  }
}
