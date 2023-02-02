// SPDX-License-Identifier: MIT License
//sample structure for projects implementating our functions to get and repay funding
//if loan applicant is a project that has not launched yet, it can still receive funding
//project simply needs to implement: receiveFunding using the correct parameters
//project needs to be fair launch
//project needs to implement taxed txs with a hardcoded repayment as illustrated in this contract
//individuals receive funding direct into their wallets

pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract sampleProject is ERC20, Ownable {
    modifier lockSwap {
        require(!_inSwap);
        _inSwap = true;
        _;
        _inSwap = false;
    }
    modifier liquidityAdd {
        _inLiquidityAdd = true;
        _;
        _inLiquidityAdd = false;
    }
    modifier reentrant {
        require(!_inTransfer);
        _inTransfer = true;
        _;
        _inTransfer = false;
    }
    uint public _buyRate = 15;//reimbursed in tokens when you sell
    uint public _sellRate = 15;//play to sell applies, anti jeet, play you not only get 0% but also wont forefeit reimbursement & rewards..be active
    uint256 public _maxHoldings = 2500000 * 1e18; //2500000 final 0.5% as we will start with 1k liquidity
    uint256 public _feeTokens;
    uint256 public _holders;
    uint256 public _tradingStart;
    uint256 public _tradingStartBlock;
    uint256 public _totalSupply;
    address public _pairAddress;
    address public _loanClub;
    address constant public _burnAddress = 0x000000000000000000000000000000000000dEaD;
    IUniswapV2Router02 internal _router = IUniswapV2Router02(address(0));
    bool internal _inSwap = false;
    bool internal _inTransfer = false;
    bool internal _inLiquidityAdd = false;
   
    mapping(address => bool) private _rewardExclude;
    mapping(address => bool) private _taxExcluded;
    mapping(address => bool) private _bot;
    mapping(address => uint256) private _tradeBlock; 
    mapping(address => uint256) private _balances;
  
    constructor() ERC20("Sample-Project", "SAMPLEP"){
        addTaxExcluded(owner());
        addTaxExcluded(address(this));
        addTaxExcluded(_burnAddress);
        //Uniswap|Pancakeswap
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        // Create a dex pair for this new token
        _pairAddress = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this),_uniswapV2Router.WETH());
        // set the rest of the contract variables
        _router = _uniswapV2Router;
    }
    function addLiquidity(uint256 tokens) public payable onlyOwner() liquidityAdd {
        _mint(address(this), tokens);
        _approve(address(this), address(_router), tokens);
        _router.addLiquidityETH{value: msg.value}(
            address(this),
            tokens,
            0,
            0,
            owner(),
            block.timestamp
        );
    }
    function circSupply() public view returns (uint256) {
        return _totalSupply - balanceOf(_burnAddress);
    }
    //taxes
    function isTaxExcluded(address account) public view returns (bool) {
        return _taxExcluded[account];
    }
    function addTaxExcluded(address account) internal {
        _taxExcluded[account] = true;
    }
    //bot accounts on uniswap|pancakeswap trading from router
    function isBot(address account) public view returns (bool) {
        return _bot[account];
    }
    function _addBot(address account) internal {
        _bot[account] = true;
        _rewardExclude[account] = true;
    }
    function addBot(address account) public onlyOwner() {
        if(account == address(_router) || account == _pairAddress){revert();}
        _addBot(account);
    }
    //token balances
    function _addBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] + amount;
    }
    function _subtractBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] - amount;
    }
    //------------------------------------------------------------------
    //Transfer overwrites erc-20 method. 
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (isTaxExcluded(sender) || isTaxExcluded(recipient)) {
            if(sender == owner() || sender == address(this) || recipient == owner() || _inLiquidityAdd) {
                _rawTransfer(sender, recipient, amount);
                return;
            }
        }
        //automatic start to trading
        require(block.number >= _tradingStartBlock);
        require(!isBot(sender) && !isBot(msg.sender) && !isBot(tx.origin));
        require(_inLiquidityAdd || _inSwap || amount <= _maxHoldings);
        if (!_inSwap && _feeTokens > 0 && recipient == _pairAddress) {
            _swap(_feeTokens);
        }
        //indicates swap
        uint256 send = amount; uint256 selltaxtokens; uint256 buytaxtokens; 
        // Buy
        if (sender == _pairAddress) {
            require(balanceOf(recipient)+amount<_maxHoldings);
            (send,buytaxtokens) = _getBuyTax(amount);
        }
        // Sell
        if (recipient == _pairAddress) {
            (send,selltaxtokens) = _getSellTax(amount, _sellRate);
        }
        //transfer
        _rawTransfer(sender, recipient, send);
        //take sell taxrevenue
        if(selltaxtokens>0){
            _takeSellTax(sender, selltaxtokens);
        }
        //take buy tax/reimbursement from recipient
        if(buytaxtokens>0){
            _takeBuyTax(sender, buytaxtokens);
        }
        //anti snipe the mev mechants
        if(sender == _pairAddress){
            _tradeBlock[recipient] = block.number;//when you buy we log block
        }
        if(recipient == _pairAddress && _tradeBlock[sender] == block.number){
            _addBot(sender);
        }
    }
    //liquidate fee tokens on each sell tx
    function _swap(uint256 amountSwap) internal lockSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _router.WETH();
        _approve(address(this), address(_router), amountSwap);
        uint256 contractEth = address(this).balance;
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountSwap,
            0,
            path,
            address(this),
            block.timestamp
        );
        uint256 repaymentPortion = address(this).balance - contractEth;
        //template used by project being funded: interface
        //in this case 100% are going to loanClub, can be smaller percentage i.e. 5%
        //check for repayment limit is recomended
        if(repaymentPortion > 0){
            (bool success,) = _loanClub.call{value: repaymentPortion}(abi.encodeWithSignature("repayProjectFunding(address)", address(this)));
            require(success, "repayment failed");
        }
        //finally adjust feeTokens
        _feeTokens -= amountSwap;
    }
    //template used by project being funded: interface
    //verified router and verified factory: from list of official ones, block custome custom fakes
    //projects being funded must make sure they have x tokens available on contract to >= _tokenReserves & _tokensAdded
    //these are minted as we add liquidity, this is the only mint function we want to see, no where else in the contract
    //first person to fund would set the initial price
    //if 1 billion tokens to be minted & 1 ETH added, then person A: myETHcontribt/totalETHraise * 1 billion = mytokensAdded
    //alt approach is to collect all the ETH in sending function, 
    //once it hits totalETHraise then the last contributor initiates the funding call & we mint the whole 1 billion once
    //later approach chosen: we avoid issues with pretrading before the whole funding is reached, affecting late contributors
    modifier fundingRound {
        _inLiquidityAdd = true;
        _;
        _inLiquidityAdd = false;
    }
    function receiveFunding(address _whc_router, address _whc_factory, address _loanClubvaultAddr, uint256 _tokensAdded) public payable fundingRound returns(address pairAddress){
        require(_tokensAdded > 0, "tokens amount required");
        require(msg.value > 0, "add eth");
        
        _mint(address(this), _tokensAdded);
        _approve(address(this), address(_whc_router), _tokensAdded);
        //trialing a call approach, alternatively have funded project implement Uniswap interface
        (bool success, bytes memory returnData) = _whc_router.call{value: msg.value}(abi.encodeWithSignature("addLiquidityETH(address,uint,uint,uint,address,uint)",address(this),_tokensAdded,0,0,_loanClubvaultAddr,block.timestamp));
        require(success, "call failed");
        (,,uint256 tokensAdded_) = abi.decode(returnData, (uint, uint, uint));
        if(tokensAdded_>0){
            address _WETHaddress = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;//weth on goerli 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6, weth on mainnet 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
            pairAddress = IUniswapV2Factory(_whc_factory).getPair(address(this),_WETHaddress);
            
        }else{revert();}
        return pairAddress;
    }
    function _paymentETH(address receiver, uint256 amount) internal {
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
    function _takeSellTax(address account, uint256 totalFees) internal {
        _feeTokens += totalFees;
        _rawTransfer(account, address(this), totalFees);
    }
    function _takeBuyTax(address sender,  uint256 totalFees) internal {
        _feeTokens += totalFees;
        _rawTransfer(sender, address(this), totalFees);
    }
    
    function _getSellTax(uint256 amount, uint rate)internal pure returns (uint256 send, uint256 tax){
        uint sendRate = 100 - rate;
        send = (amount * sendRate) / 100; 
        tax = amount - send;
        return(send, tax);
    }
    function _getBuyTax(uint256 amount)internal view returns (uint256 send, uint256 tax){
        tax = (amount * _buyRate) / 100;
        send = amount - tax;
        return(send, tax);
    }
    //setters
    function setloanClub(address payable _wallet) external onlyOwner(){
        _loanClub = _wallet;
    }
    function setBuyTax(uint rate) external onlyOwner() {
        require( rate >= 0 && rate <= 25); 
        _buyRate = rate;
    }
    function setMaxHoldings(uint256 maxHoldings) external onlyOwner() {
        require(_maxHoldings <= 10000000 * 1e18);
        _maxHoldings = maxHoldings;
    }
    function setSellTax(uint rate) external onlyOwner() {
        require( rate >= 0 && rate <= 25); 
        _sellRate = rate;
    }
    function setTradingStart(uint startblock) external onlyOwner() {
        require( _tradingStartBlock == 0 ); 
        _tradingStartBlock = startblock;
        _tradingStart = block.timestamp;
    }
    // modified from OpenZeppelin ERC20
    function _rawTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        require(sender != address(0));
        require(recipient != address(0));

        uint256 senderBalance = balanceOf(sender);
        require(senderBalance >= amount);
        unchecked {
            _subtractBalance(sender, amount);
        }
        _addBalance(recipient, amount);
        emit Transfer(sender, recipient, amount);
    }
    function balanceOf(address account) public view virtual override returns (uint256){
        return _balances[account];
    }
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }
    function _mint(address account, uint256 amount) internal override {
        require(_totalSupply < 500000001 * 1e18);
        _totalSupply += amount;
        _addBalance(account, amount);
        emit Transfer(address(0), account, amount);
    }
    receive() external payable {}
}
