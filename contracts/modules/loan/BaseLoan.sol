pragma solidity ^0.8.9;

// Helpers
import { LoanLib } from "../../utils/LoanLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// module interfaces 
import { ILoan } from "../../interfaces/ILoan.sol";
import { IEscrow } from "../../interfaces/IEscrow.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

abstract contract BaseLoan is ILoan {  
  address immutable public borrower;   // borrower being lent to
  address immutable public oracle; 
  address immutable public arbiter;
  address immutable public interestRateModel;

  mapping(bytes32 => DebtPosition) public debts; // positionId -> DebtPosition

  // Loan Financials aggregated accross all existing  DebtPositions
  LoanLib.STATUS public loanStatus;

  bytes32[] public positionIds; // all active positions

  // all deonminated in USD
  uint256 public principal; // initial loan  drawdown
  uint256 public totalInterestAccrued;// unpaid interest

  // i dont think we need to keep global var on this. only check per debt position
  uint256 immutable public maxDebtValue; // total amount of USD value to be pulled from loan


  /**
   * @dev - Loan borrower and proposed lender agree on terms
            and add it to potential options for borrower to drawdown on
   * @param maxDebtValue_ - total debt accross all lenders that borrower is allowed to create
   * @param oracle_ - price oracle to use for getting all token values
   * @param arbiter_ - neutral party with some special priviliges on behalf of borrower and lender
   * @param borrower_ - the debitor for all debt positions in this contract
   * @param interestRateModel_ - contract calculating lender interest from debt position values
  */
  constructor(
    uint256 maxDebtValue_,
    address oracle_,
    address arbiter_,
    address borrower_,
    address interestRateModel_
  ) {
    maxDebtValue = maxDebtValue_;

    borrower = borrower_;
    interestRateModel = interestRateModel_;
    arbiter = arbiter_;
    oracle = oracle_;

    loanStatus = LoanLib.STATUS.ACTIVE;
  }

  ///////////////
  // MODIFIERS //
  ///////////////

  modifier isActive() {
    require(loanStatus == LoanLib.STATUS.ACTIVE, 'Loan: no op');
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

  modifier validPositionId(bytes32 positionId) {
    require(debts[positionId].lender != address(0), "Loan: invalid position ID");
    _;
  }
  ///////////
  // HOOKS //
  ///////////

  /**
   * @dev  Used to addc custom liquidation functionality until we create separate Liquidation module
   * @param positionId - deterministic id of loan
   * @param amount - expected amount of `targetToken` to be liquidated
   * @param targetToken - token to liquidate to repay debt
   * @return amount of tokens actually liquidated
  */
  function _liquidate(
    bytes32 positionId,
    uint256 amount,
    address targetToken
  )
    virtual internal
    returns(uint256)
  {
    return 0;
  }


  /**
   * @notice  Get amount of debt that borrower is currently allowed to repay.
   * @dev Modules can overwrite e.g. for bullet loans to prevent principal repayments
   * @param positionId - debt position data for loan being repaid
   * @param requestedRepayAmount - amount of debt that the borrower would like to pay
   * @return - amount borrower is allowed to repay. Returns 0 if repayment is not allowed
  */
  function _getMaxRepayableAmount(
    bytes32 positionId,
    uint256 requestedRepayAmount
  )
    virtual internal
    returns(uint256)
  {
    uint256 totalOwed = debts[positionId].principal + debts[positionId].interestAccrued;

    // cap repayable amount by total outstanding debt
    return totalOwed > requestedRepayAmount ? requestedRepayAmount : totalOwed;
  }


  /**
   * @dev  Calls interestRate contract and gets amount of interest owned on debt position
   * @param positionId - debt position data for loan being calculated
   * @return total interest to add to position
  */
  function _getInterestPaymentAmount(bytes32 positionId)
    virtual internal
    returns(uint256) {}

  function _close(bytes32 positionId) virtual internal returns(bool) {    
    require(
      debts[positionId].principal + debts[positionId].interestAccrued == 0,
      'Loan: close failed. debt owed'
    );

    delete debts[positionId]; // yay gas refunds!!!

    emit CloseDebtPosition(positionId);    

    return true;
  }

  function healthcheck() external returns(LoanLib.STATUS) {
    // if loan is in a final end state then do not run _healthcheck()
    if(loanStatus == LoanLib.STATUS.REPAID || loanStatus == LoanLib.STATUS.INSOLVENT) {
      return loanStatus;
    }
    return _updateLoanStatus(_healthcheck());
  }
  /**
   *  @notice - loops through all modules and returns their status if required last to savegas on override external calls
   *        returns early if returns non-ACTIVE
  */
  function _healthcheck() virtual internal returns(LoanLib.STATUS status) {
    if(principal + totalInterestAccrued > maxDebtValue)
      return LoanLib.STATUS.OVERDRAWN;

    return LoanLib.STATUS.ACTIVE;
  }
  
  /**
  @dev Returns total debt obligation of borrower.
       Aggregated across all lenders.
       Denominated in USD 1e8.
  */
  function getOutstandingDebt() override external returns(uint256) {
    return principal + totalInterestAccrued;
  }

  // Liquidation
  /**
   * @notice - Forcefully take collateral from borrower and repay debt for lender
   * @dev - only called by neutral arbiter party/contract
   * @dev - `loanStatus` must be LIQUIDATABLE
   * @param positionId -the debt position to pay down debt on
   * @param amount - amount of `targetToken` expected to be sold off in  _liquidate
   * @param targetToken - token that is expected to be sold of to repay positionId
   */

  function liquidate(
    bytes32 positionId,
    uint256 amount,
    address targetToken
  )
    onlyArbiter
    validPositionId(positionId)
    external
    returns(uint256)
  {
    _updateLoanStatus(_healthcheck());
    require(loanStatus == LoanLib.STATUS.LIQUIDATABLE, "Loan: not liquidatable");
    return _liquidate(positionId, amount, targetToken);
  }


  /**
    @notice see _accrueInterest()
  */
  function accrueInterest() virtual override external returns(uint256 accruedValue) {
    uint256 len = positionIds.length;

    for(uint256 i = 0; i < len; i++) {
      (, uint256 accruedTokenValue) = _accrueInterest(positionIds[i]);
      accruedValue += accruedTokenValue;
    }

  }
  ///////////////
  // REPAYMENT //
  ///////////////

  /**
   * @dev - Transfers token used in debt position from msg.sender to Loan contract.
   * @notice - see _repay() for more details
   * @param positionId -the debt position to pay down debt on
   * @param amount - amount of `token` in `positionId` to pay back
  */

  function depositAndRepay(
    bytes32 positionId,
    uint256 amount
  )
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest(positionId);

    uint256 amountToRepay = _getMaxRepayableAmount(positionId, amount);
    require(amountToRepay > 0, "Loan: nothing to repay yet");

    bool success = IERC20(debts[positionId].token).transferFrom(
      msg.sender,
      address(this),
      amountToRepay
    );
    require(success, 'Loan: failed repayment');

    _repay(positionId, amountToRepay);
    return true;
  }

   /**
   * @dev - Transfers enough tokens to repay entire debt position from `borrower` to Loan contract.
            Only callable by borrower bc it closes position.
   * @param positionId -the debt position to pay down debt on and close
  */
  function depositAndClose(bytes32 positionId)
    onlyBorrower
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];

    uint256 totalOwed = debt.principal + debt.interestAccrued;
    require(totalOwed == _getMaxRepayableAmount(positionId, totalOwed), "Loan: can't repay whole position");

    // borrower deposits remaining balance not already repaid and held in contract
    bool success = IERC20(debt.token).transferFrom(
      msg.sender,
      address(this),
      totalOwed
    );
    require(success, 'Loan: deposit failed');
    // clear the debt 
    _repay(positionId, totalOwed);

    require(_close(positionId));
    return true;
  }
  
  ////////////////////
  // FUND TRANSFERS //
  ////////////////////
     /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function borrow(bytes32 positionId, uint256 amount)
    isActive
    onlyBorrower
    validPositionId(positionId)
    override external
    returns(bool)
  {
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <= debt.deposit - debt.principal, 'Loan: no liquidity');

    debt.principal += amount;

    (bool passed, bytes memory result) = debt.token.call(abi.encodeWithSignature("decimals()"));
   
    principal += (_getTokenPrice(debt.token) * amount) / debt.decimals;

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


    emit Borrow(positionId, amount);

    return true;
  }

   /**
   * @dev - Transfers tokens from Loan to lender.
   *        Only allowed to withdraw tokens not already lent out (prevents bank run)
   * @param positionId -the debt position to pay down debt on and close
   * @param amount - amount of tokens lnder would like to withdraw (withdrawn amount may be lower)
  */
  function withdraw(bytes32 positionId, uint256 amount) override external returns(bool) {
    require(msg.sender == debts[positionId].lender, "Loan: only lender can withdraw");
    
    _accrueInterest(positionId);
    DebtPosition memory debt = debts[positionId];
    
    require(amount <=  debt.deposit + debt.interestRepaid - debt.principal, 'Loan: no liquidity');

    if(amount > debt.interestRepaid) {
      debt.deposit -= amount - debt.interestRepaid;
      debt.interestRepaid = 0;
    } else {
      debt.interestRepaid -= amount;
    }

    bool success = IERC20(debt.token).transfer(
      debt.lender,
      amount
    );
    require(success, 'Loan: withdraw failed');

    debts[positionId] = debt;

    emit Withdraw(positionId, amount);

    return true;
  }


  /**
   * @dev - Deletes debt position preventing any more borrowing.
   *      - Only callable by borrower or lender for debt position
   *      - Requires that the debt has already been paid off
   * @param positionId -the debt position to close
  */
  function close(bytes32 positionId) validPositionId(positionId) override external returns(bool) {
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

  // privileged internal functions
  /**
   * @dev - Reduces `principal` and/or `interestAccrued` on debt position, increases lender's `deposit`.
            Reduces global USD principal and totalInterestAccrued values.
            Expects checks for conditions of repaying and param sanitizing before calling
            e.g. early repayment of principal, tokens have actually been paid by borrower, etc.
   * @param positionId - debt position struct with all data pertaining to loan
   * @param amount - amount of token being repaid on debt position
  */
  function _repay(
    bytes32 positionId,
    uint256 amount
  )
    virtual internal
    returns(bool)
  {
    return true;
  }

  /**
   * @dev - Loops over all debt positions, calls InterestRate module with position data,
            then updates `interestAccrued` on position with returned data.
            Also updates global USD values for `totalInterestAccrued`.
            Can only be called when loan is not in distress
  */
  function _accrueInterest(bytes32 positionId)
    internal
    returns (uint256 accruedToken, uint256 accruedValue)
  {
    // get token demoninated interest accrued
    accruedToken = _getInterestPaymentAmount(positionId);

    // update debts balance
    debts[positionId].interestAccrued += accruedToken;

    // get USD value of interest accrued
    accruedValue = (_getTokenPrice(debts[positionId].token) * accruedToken) / debts[positionId].decimals;
    totalInterestAccrued += accruedValue;

    emit InterestAccrued(positionId, accruedToken, accruedValue);

    return (accruedToken, accruedValue);
  }

  function _createDebtPosition(
    address lender,
    address token,
    uint256 amount
  )
    internal
    returns(bytes32 positionId)
  {
    require(IOracle(oracle).getLatestAnswer(token) > 0, "Loan: token cannot be valued");
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
      principal: 0,
      interestAccrued: 0,
      interestRepaid: 0,
      init: false
    });

    emit AddDebtPosition(lender, token, amount);

    return positionId;
  }


  // Helper functions
  function _updateLoanStatus(LoanLib.STATUS status) internal returns(LoanLib.STATUS) {
    if(loanStatus == status) return loanStatus;
    loanStatus = status;
    emit UpdateLoanStatus(uint256(status));
    return status;
  }

  /**
   * @dev - Calls Oracle module to get most recent price for token.
            All prices denominated in USD.
   * @param token - token to get price for
  */
  function _getTokenPrice(address token) internal returns (uint256) {
    return IOracle(oracle).getLatestAnswer(token);
  }
}
