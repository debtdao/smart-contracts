pragma solidity 0.8.9;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title SpigotController
 * @author Kiba Gateaux
 * @notice Contract allowing Owner to secure revenue streams from a DAO and split payments between them
 * @dev Should be deployed once per loan. Can attach multiple revenue contracts
 */
contract SpigotController is ReentrancyGuard {

    struct SpigotSettings {
        address token;                // token to claim as revenue from contract
        uint8 ownerSplit;             // x/100 % to Owner, rest to Treasury
        bytes4 claimFunction;         // function signature on contract to call and claim revenue
        bytes4 transferOwnerFunction; // function signature on conract to call and transfer ownership 
    }

    // Constants 

    // Maximum numerator for SpigotSettings.ownerSplit param
    uint8 constant MAX_SPLIT =  100;
    // cap revenue per claim to avoid overflows on multiplication when calculating percentages
    uint256 constant MAX_REVENUE = type(uint).max / MAX_SPLIT;

    // Spigot variables

    // Total amount of tokens escrowed by spigot
    mapping(address => uint256) escrowed; // token  -> amount escrowed
    // Configurations for revenue contracts to split
    mapping(address => SpigotSettings) settings; // revenue contract -> settings
    //  allowed by operator on all revenue contracts
    mapping(bytes4 => bool) whitelistedFunctions; // function -> allowed

    event AddSpigot(address indexed revenueContract, address token, uint256 ownerSplit);

    event RemoveSpigot (address indexed revenueContract, address token);

    event UpdateWhitelistFunction(bytes4 indexed func, bool indexed allowed);

    event ClaimRevenue(address indexed token, uint256 indexed amount, uint256 escrowed, address revenueContract);

    event ClaimEscrow(address indexed token, uint256 indexed amount, address owner);

    // Stakeholder variables
    address public owner;

    address public operator;

    address public treasury;

    event UpdateOwner(address indexed newOwner);

    event UpdateOperator(address indexed newOperator);

    event UpdateTreasury(address indexed newTreasury);

    /**
     *
     * @dev Configure data for contract owners and initial revenue contracts.
            Owner/operator/treasury can all be the same address
     * @param _owner Third party that owns rights to contract's revenue stream
     * @param _treasury Treasury of DAO that owns contract and receives leftover revenues
     * @param _operator Operational account of DAO that actively manages contract health
     *
     */
    constructor (
        address _owner,
        address _treasury,
        address _operator
    ) {
        require(address(0) != _owner);
        require(address(0) != _treasury);
        require(address(0) != _operator);

        owner = _owner;
        operator = _operator;
        treasury = _treasury;
    }



    // ##########################
    // #####   Claimoooor   #####
    // ##########################

    /**

     * @notice - Claim push/pull payments through Spigots.
                 Calls predefined function in contract settings to claim revenue.
                 Automatically sends portion to treasury and escrows Owner's share.
     * @dev - callable by anyone
     * @param revenueContract Contract with registered settings to claim revenue from
     * @param data  Transaction data, including function signature, to properly claim revenue on revenueContract
     * @return claimed -  The amount of tokens claimed from revenueContract and split in payments to `owner` and `treasury`
    */
    function claimRevenue(address revenueContract, bytes calldata data)
        external nonReentrant
        returns (uint256 claimed)
    {
        address token = settings[revenueContract].token;
        claimed = _claimRevenue(revenueContract, data, token);

        // split revenue stream according to settings
        uint256 escrowedAmount = claimed * settings[revenueContract].ownerSplit / 100;
        // update escrowed balance
        escrowed[token] = escrowed[token] + escrowedAmount;
        
        // send non-escrowed tokens to Treasury if non-zero
        if(claimed > escrowedAmount) {
            require(_sendOutTokenOrETH(token, treasury, claimed - escrowedAmount));
        }

        emit ClaimRevenue(token, claimed, escrowedAmount, revenueContract);
        
        return claimed;
    }


     function _claimRevenue(address revenueContract, bytes calldata data, address token)
        internal
        returns (uint256 claimed)
    {
        uint256 existingBalance = _getBalance(token);
        if(settings[revenueContract].claimFunction == bytes4(0)) {
            // push payments
            // claimed = total balance - already accounted for balance
            claimed = existingBalance - escrowed[token];
        } else {
            // pull payments
            require(bytes4(data) == settings[revenueContract].claimFunction, "Spigot: Invalid claim function");
            (bool claimSuccess, bytes memory claimData) = revenueContract.call(data);
            require(claimSuccess, "Spigot: Revenue claim failed");
            // claimed = total balance - existing balance
            claimed = _getBalance(token) - existingBalance;
        }

        require(claimed > 0, "Spigot: No revenue to claim");
        if(claimed > MAX_REVENUE) claimed = MAX_REVENUE;

        return claimed;
    }

    /**
     * @notice - Allows Spigot Owner to claim escrowed tokens from a revenue contract
     * @dev - callable by `owner`
     * @param token Revenue token that is being escrowed by spigot
     * @return claimed -  The amount of tokens claimed from revenue garnish by `owner`

    */
    function claimEscrow(address token) external nonReentrant returns (uint256 claimed)  {
        require(msg.sender == owner);

        claimed = escrowed[token];

        require(claimed > 0, "Spigot: No escrow to claim");

        require(_sendOutTokenOrETH(token, owner, claimed));

        escrowed[token] = 0; // keep 1 in escrow for recurring call gas optimizations?

        emit ClaimEscrow(token, claimed, owner);

        return claimed;
    }

    /**
     * @notice - Retrieve amount of tokens tokens escrowed waiting for claim
     * @param token Revenue token that is being garnished from spigots
    */
    function getEscrowBalance(address token) external view returns (uint256) {
        return escrowed[token];
    }



    // ##########################
    // ##### *ring* *ring*  #####
    // #####  OPERATOOOR    #####
    // #####  OPERATOOOR    #####
    // ##########################

    /**
     * @notice - Allows Operator to call whitelisted functions on revenue contracts to maintain their product
     *           while still allowing Spigot Owner to own revenue stream from contract
     * @dev - callable by `operator`
     * @param revenueContract - smart contract to call
     * @param data - tx data, including function signature, to call contract with
     */
    function operate(address revenueContract, bytes calldata data) external returns (bool) {
        require(msg.sender == operator);
        return _operate(revenueContract, data);
    }

    /**

     * @notice - operate() on multiple contracts in one tx
     * @dev - callable by `operator`
     * @param contracts - smart contracts to call
     * @param data- tx data, including function signature, to call contracts with
     */
    function doOperations(address[] calldata contracts, bytes[] calldata data) external returns (bool) {
        require(msg.sender == operator);
        for(uint256 i = 0; i < data.length; i++) {
            _operate(contracts[i], data[i]);
        }
        return true;
    }

    /**
     * @notice - Checks that operation is whitelisted by Spigot Owner and calls revenue contract with supplied data
     * @param revenueContract - smart contracts to call
     * @param data - tx data, including function signature, to call contracts with
     */
    function _operate(address revenueContract, bytes calldata data) internal nonReentrant returns (bool) {
        // extract function signature from tx data and check whitelist
        require(whitelistedFunctions[bytes4(data)], "Spigot: Unauthorized action");
        // cant claim revenue via operate() because that fucks up accounting logic. Owner shouldn't whitelist it anyway but just in case
        require(settings[revenueContract].claimFunction != bytes4(data), "Spigot: Unauthorized action");

        
        (bool success, bytes memory opData) = revenueContract.call(data);
        require(success, "Spigot: Operation failed");

        return true;
    }



    // ##########################
    // #####  Maintainooor  #####
    // ##########################

    /**
     * @notice Allow owner to add new revenue stream to spigot
     * @dev - callable by `owner`
     * @param revenueContract - smart contract to claim tokens from
     * @param setting - spigot settings for smart contract   
     */
    function addSpigot(address revenueContract, SpigotSettings memory setting) external returns (bool) {
        require(msg.sender == owner);
        return _addSpigot(revenueContract, setting);
    }

    /**
     * @notice Checks  revenue contract doesn't already have spigot
     *      then registers spigot configuration for revenue contract
     * @param revenueContract - smart contract to claim tokens from
     * @param setting - spigot configuration for smart contract   
     */
    function _addSpigot(address revenueContract, SpigotSettings memory setting) internal returns (bool) {
        require(revenueContract != address(this));
        require(
          settings[revenueContract].transferOwnerFunction == bytes4(0),
          "Spigot: Setting already exists"
        );
        
        require(setting.transferOwnerFunction != bytes4(0), "Spigot: Invalid spigot setting");
        require(setting.ownerSplit <= MAX_SPLIT && setting.ownerSplit >= 0, "Spigot: Invalid split rate");
        
        settings[revenueContract] = setting;
        emit AddSpigot(revenueContract, setting.token, setting.ownerSplit);

        return true;
    }

    /**

     * @notice - Change owner of revenue contract from Spigot (this contract) to Operator.
     *      Sends existing escrow to current Owner.
     * @dev - callable by `owner`
     * @param revenueContract - smart contract to transfer ownership of
     */
    function removeSpigot(address revenueContract) external returns (bool) {
        require(msg.sender == owner);
        
        address token = settings[revenueContract].token;
        uint256 claimable = escrowed[token];
        if(claimable > 0) {
            require(_sendOutTokenOrETH(token, owner, claimable));
            emit ClaimEscrow(token, claimable, owner);
        }
        
        (bool success, bytes memory callData) = revenueContract.call(
            abi.encodeWithSelector(
                settings[revenueContract].transferOwnerFunction,
                operator    // assume function only takes one param that is new owner address
            )
        );
        require(success);

        delete settings[revenueContract];
        emit RemoveSpigot(revenueContract, token);

        return true;
    }

    function updateOwnerSplit(address revenueContract, uint8 ownerSplit) external returns(bool) {
      require(msg.sender == owner, 'Spigot: only owner updates split');
      require(ownerSplit >= 0 && ownerSplit <= MAX_SPLIT, 'Spigot: invalid owner split');

      settings[revenueContract].ownerSplit = ownerSplit;
      return true;
    }
    /**

     * @notice - Update Owner role of SpigotController contract.
     *      New Owner receives revenue stream split and can control SpigotController
     * @dev - callable by `owner`
     * @param newOwner - Address to give control to
     */
    function updateOwner(address newOwner) external returns (bool) {
        require(msg.sender == owner);
        require(newOwner != address(0));
        owner = newOwner;
        emit UpdateOwner(newOwner);
        return true;
    }

    /**

     * @notice - Update Operator role of SpigotController contract.
     *      New Operator can interact with revenue contracts.
     * @dev - callable by `operator`
     * @param newOperator - Address to give control to
     */
    function updateOperator(address newOperator) external returns (bool) {
        require(msg.sender == operator);
        require(newOperator != address(0));
        operator = newOperator;
        emit UpdateOperator(newOperator);
        return true;
    }
    
    /**

     * @notice - Update Treasury role of SpigotController contract.
     *      New Treasury receives revenue stream split
     * @dev - callable by `treasury`
     * @param newTreasury - Address to divert funds to
     */
    function updateTreasury(address newTreasury) external returns (bool) {
        require(msg.sender == treasury || msg.sender == operator);
        require(newTreasury != address(0));
        treasury = newTreasury;
        emit UpdateTreasury(newTreasury);
        return true;
    }

    /**

     * @notice - Allows Owner to whitelist function methods across all revenue contracts for Operator to call.
     *           Can whitelist "transfer ownership" functions on revenue contracts
     *           allowing Spigot to give direct control back to Operator.
     * @dev - callable by `owner`
     * @param func - smart contract function signature to whitelist
     * @param allowed - true/false whether to allow this function to be called by Operator
     */
     function updateWhitelistedFunction(bytes4 func, bool allowed) external returns (bool) {
        require(msg.sender == owner);
        return _updateWhitelist(func, allowed);
    }

    /**

     * @notice - Allows Owner to whitelist function methods across all revenue contracts for Operator to call.
     * @param func - smart contract function signature to whitelist
     * @param allowed - true/false whether to allow this function to be called by Operator
     */
    function _updateWhitelist(bytes4 func, bool allowed) internal returns (bool) {
        whitelistedFunctions[func] = allowed;
        emit UpdateWhitelistFunction(func, true);
        return true;
    }

    /**

     * @notice - Send ETH or ERC20 token from this contract to an external contract
     * @param token - address of token to send out. address(0) for raw ETH
     * @param receiver - address to send tokens to
     * @param amount - amount of tokens to send
     */
    function _sendOutTokenOrETH(address token, address receiver, uint256 amount) internal returns (bool) {
        if(token!= address(0)) { // ERC20
            IERC20(token).transfer(receiver, amount);
        } else { // ETH
            (bool success, bytes memory data) = payable(receiver).call{value: amount}("");
            require(success, "Spigot: Disperse escrow failed");
        }
        return true;
    }

    /**

     * @notice - Helper function to get current balance of this contract for ERC20 or ETH
     * @param token - address of token to check. address(0) for raw ETH
     */
    function _getBalance(address token) internal view returns (uint256) {
        return token != address(0) ?
            IERC20(token).balanceOf(address(this)) :
            address(this).balance;
    }

    // GETTERS

    function getSetting(address revenueContract)
        external view
        returns(address, uint8, bytes4, bytes4)
    {   
        return (
            settings[revenueContract].token,
            settings[revenueContract].ownerSplit,
            settings[revenueContract].claimFunction,
            settings[revenueContract].transferOwnerFunction
        );
    }

    receive() external payable {
        return;
    }

}
