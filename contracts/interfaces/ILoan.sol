import { LoanLib } from "../utils/LoanLib.sol";

interface ILoan {

  // General Events
  event UpdateLoanStatus(uint256 indexed status); // store as normal uint so it can be indexed in subgraph

  event DeployLoan(
    address indexed oracle,
    address indexed arbiter,
    address indexed borrower
  );

  // Lender Events

  event AddDebtPosition(
    address indexed lender,
    address indexed token,
    uint256 indexed deposit,
    uint256 initialPrincipal
  );
  // can reference only positionId once AddDebtPosition is emitted because it will be stored in subgraph
  // initialPrinicipal tells us if its a Revolver or Term

  event WithdrawDeposit(bytes32 indexed positionId, uint256 indexed amount);
  // lender removing funds from Loan  principal
  event WithdrawProfit(bytes32 indexed positionId, uint256 indexed amount);
  // lender taking interest earned out of contract

  event CloseDebtPosition(bytes32 indexed positionId);
  // lender officially repaid in full. if Credit then facility has also been closed.

  event InterestAccrued(bytes32 indexed positionId, uint256 indexed amount, uint256 indexed value);
  // interest added to borrowers outstanding balance


  // Borrower Events

  event Borrow(bytes32 indexed positionId, uint256 indexed amount, uint256 indexed value);
  // receive full loan or drawdown on credit

  event RepayInterest(bytes32 indexed positionId, uint256 indexed amount, uint256 indexed value);

  event RepayPrincipal(bytes32 indexed positionId, uint256 indexed amount, uint256 indexed value);

  event Default(bytes32 indexed positionId, uint256 indexed amount, uint256 indexed value);

  // External Functions  
  function withdraw(bytes32 positionId, uint256 amount) external returns(bool);

  function depositAndRepay(uint256 amount) external returns(bool);
  function depositAndClose() external returns(bool);

  function accrueInterest() external returns(uint256 valueAccrued);
  function getOutstandingDebt() external returns(uint256 totalDebt);
  function healthcheck() external returns(LoanLib.STATUS);
}
