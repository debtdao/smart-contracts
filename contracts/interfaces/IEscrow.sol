pragma solidity 0.8.9;

interface IEscrow {
    struct Deposit {
        uint amount;
        bool isERC4626;
        address asset; // eip4626 asset else the erc20 token itself
        uint8 assetDecimals;
    }

    event AddCollateral(address indexed token, uint indexed amount);
    event RemoveCollateral(address indexed token, uint indexed amount);
    event Liquidate(address indexed token, uint indexed amount);

    function addCollateral(uint amount, address token) external returns(uint);

    function getCollateralRatio() external returns(uint);

    function getCollateralValue() external returns(uint);
    
    function releaseCollateral(uint amount, address token, address to) external returns(uint);

    function liquidate(uint amount, address token, address to) external returns(bool);
}
