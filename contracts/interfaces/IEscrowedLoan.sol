interface IEscrowedLoan {
  event Liquidate(bytes32 indexed positionId, uint256 indexed amount, address indexed token);

  function liquidate(bytes32 positionId, uint256 amount, address targetToken) external returns(uint256);
}
