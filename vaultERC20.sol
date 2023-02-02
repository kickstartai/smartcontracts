// SPDX-License-Identifier: MIT
//keeping it simple: deposits are open (Uniswap or manual send)
//withdrawals only by  manager
//OUR VAULT SERVES:
//1. to receive any ERC20 token as a deposit
//2. allow people to own the rights to withdrawing these tokens
//3. allow collateral profiles to be created and reference by lending contract
//token withdrawals terms:
//1. Manager can withdraw (if other project fucks around) but should be trusted not to just withdraw tokens, 
//2. project owner should be able to withdraw if repayments have been made in full
// - projects want to renounce to gain trust therefore give function to assign withdrawer for when repayments are paid
// - make sure to assign before renouncing, otherwise seek Manager for help

pragma solidity ^0.8.4;

import "./MemeBank.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KICKSTART_ERC20_Vault is Ownable {
    lendingClub private loanclubInst;
    address public tokenAddress;
    address public loanclubAddress;
    address public ownerAddress;
    uint256 public balance;
    mapping(address => holdings) projectLP;
    struct holdings{
        uint256 amount;
        address withdrawWallet;
        uint256 dateIn;//mapped or deposited 
        uint256 dateOut;
        bool locked;
    }
    
    event TransferReceived(address _from, uint _amount);
    event TransferSent(address _from, address _destAddr, uint _amount);
    event mappedLP(address indexed project, address indexed lpadddress, address indexed mapper, uint256 time);

    constructor(address payable _tokenAdd) {
		require(_tokenAdd != address(0) );
		loanclubInst = lendingClub(_tokenAdd);
        ownerAddress = msg.sender;
    }
    
    receive() payable external {
        balance += msg.value;
        emit TransferReceived(msg.sender, msg.value);
    }    
    //accidental ETH cleanup
    function withdraw(uint amount, address payable destAddr) public onlyOwner(){
        require(msg.sender == ownerAddress, "Only owner can withdraw funds"); 
        require(amount <= balance, "Insufficient funds");
        
        destAddr.transfer(amount);
        balance -= amount;
        emit TransferSent(msg.sender, destAddr, amount);
    }
    //ERC20 token cleanup
    function transferERC20(IERC20 token, address to, uint256 amount) public onlyOwner(){
        require(msg.sender == ownerAddress, "Only owner can withdraw funds"); 
        uint256 erc20balance = token.balanceOf(address(this));
        require(amount <= erc20balance, "balance is low");
        token.transfer(to, amount);
        emit TransferSent(msg.sender, to, amount);
    }
    //owner withdrawal after repayments
    function withdrawERC20(IERC20 token, address to, uint256 amount) public {
        require(msg.sender == ownerAddress, "Only owner can withdraw funds"); 
        uint256 erc20balance = token.balanceOf(address(this));
        require(amount <= erc20balance, "balance is low");
        token.transfer(to, amount);
        emit TransferSent(msg.sender, to, amount);
    }
    //map your project LP tokens to self(owner) or another address to withdraw after full repayments
    //should be done by project owner
    function assignLPtokens(IERC20 tokenAddr, address _projectAddr, address _liquidityAddr, address _assignWithdrawer) public{
        require(address(_projectAddr) != address(0),"cannot be address 0");
        bool mapAllowed = loanclubInst.mapPermissions(msg.sender, _projectAddr, _liquidityAddr);//returns bool if im owner
        if(!mapAllowed){revert("youre not owner");}
        uint256 tokensAmnt = getBalanceLP(tokenAddr);
        //proceed to map to self as withdrawer or assign new withdrawer address
        if(_assignWithdrawer == address(0)){
            projectLP[_liquidityAddr].withdrawWallet = msg.sender;
        }else{
            projectLP[_liquidityAddr].withdrawWallet = _assignWithdrawer;
        }
        projectLP[_liquidityAddr].amount = tokensAmnt;
        projectLP[_liquidityAddr].dateIn = block.timestamp;
        emit mappedLP(_projectAddr, _liquidityAddr, msg.sender, block.timestamp);
    }
    //getters
    //get balance by project LP address
    function getBalanceLP(IERC20 tokenAddr) public view returns(uint256 balanceLP){
        balanceLP = tokenAddr.balanceOf(address(this));
        return balanceLP;
    }
    function getDeposit(IERC20 liquidityAddr, address _liquidityAddr) public view returns(uint256 balanceLP, address withdrawWallet, uint256 dateIn, uint256 dateOut, bool locked){
        balanceLP = liquidityAddr.balanceOf(address(this));
        withdrawWallet = projectLP[_liquidityAddr].withdrawWallet;
        dateIn = projectLP[_liquidityAddr].dateIn;
        dateOut = projectLP[_liquidityAddr].dateOut;
        locked = projectLP[_liquidityAddr].locked;
        return (balanceLP,withdrawWallet,dateIn,dateOut,locked);
    }
    //setters
    function setlendingClub(address _address) external onlyOwner(){
        loanclubAddress = _address;
    }
    function setTokenAddress(address _address) external onlyOwner(){
        tokenAddress = _address;
    }
}
