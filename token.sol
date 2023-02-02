// SPDX-License-Identifier: MIT License
//kickstartai.xyz
//ai powered lending platform
pragma solidity ^0.8.17;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract KickStart is ERC20, Ownable {
    modifier admin(){
		require(msg.sender == _adminWallet);
		_;
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
    uint public _taxLimit = 20;
    uint public _buyTax = 5;
    uint public _sellTax = 10;
    uint private _passcode;
    uint256 public _maxHoldings = 20000000 * 1e18;
    uint256 public _feeTokens;
    uint256 private _tradingStart;
    uint256 public _tradingStartBlock;
    uint256 public _totalSupply;
    address public _pairAddress;
    address public _adminWallet;
    address payable public _marketingWallet;
    address payable public _devWallet;
    address constant public _burnAddress = 0x000000000000000000000000000000000000dEaD;
    IUniswapV2Router02 internal _router = IUniswapV2Router02(address(0));
    bool public tradingOpen;
    bool internal _inSwap = false;
    bool internal _inTransfer = false;
    bool internal _inLiquidityAdd = false;
   
    mapping(address => bool) private _rewardExclude;
    mapping(address => bool) private _bot;
    mapping(address => bool) private _preTrade;
    mapping(address => bool) public _taxExcluded;
    mapping(address => uint256) private _tradeBlock;
    mapping(address => uint256) private _balances;
  
    constructor(address payable devAddr, address payable marketingAddr) ERC20("Kickstart-AI", "KAI"){
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        _pairAddress = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this),_uniswapV2Router.WETH());
        _router = _uniswapV2Router;
        _marketingWallet = marketingAddr;
        _devWallet = devAddr;
        _addTaxExcluded(msg.sender);
        _addTaxExcluded(address(this));
        _addTaxExcluded(_burnAddress);
        
    }
    function accidentalEthSweep(uint passcode) public payable admin(){
        require(passcode == _passcode);
        uint256 accidentalETH = address(this).balance;
        _paymentETH(_marketingWallet, accidentalETH);
    }
    function circulatingSupply() public view returns (uint256) {
        return _totalSupply - balanceOf(_burnAddress);
    }
    function isTaxExcluded(address account) public view returns (bool) {
        return _taxExcluded[account];
    }
    function _addTaxExcluded(address account) internal {
        _taxExcluded[account] = true;
    }
    function addExcluded(address account) public admin() {
        _taxExcluded[account] = true;
    }
    function addExcludedArray(address[] calldata accounts) public admin() {
        for(uint256 i = 0; i < accounts.length; i++) {
                 _taxExcluded[accounts[i]] = true;
        }
    }
    function addLiquidity(address wallet1, address wallet2) public payable onlyOwner() liquidityAdd {
        uint256 tokens = 1000000000 * 1e18;
        uint256 amountW = (tokens * 2) / 100;
        uint256 balance = tokens - amountW - amountW;
        _mint(wallet1, amountW);_mint(wallet2, amountW);
        _mint(address(this), balance);
        _approve(address(this), address(_router), balance);
        _router.addLiquidityETH{value: msg.value}(
            address(this),
            balance,
            0,
            0,
            owner(),
            block.timestamp
        );
    }
    
    //_transfer overrides erc-20 transfer 
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (isTaxExcluded(sender) || isTaxExcluded(recipient)) {
            _rawTransfer(sender, recipient, amount);
            return;
        }
        if(recipient == _pairAddress && _tradeBlock[sender] == block.number){
            _addBot(sender);
        }
        require(_tradingStartBlock != 0 && block.number >= _tradingStartBlock);
        require(!isBot(sender) && !isBot(recipient));
        require(amount <= _maxHoldings);
        if (_feeTokens > 0 && recipient == _pairAddress) {
            _liquidateFee(_feeTokens);
        }
        uint256 send = amount; uint256 selltaxtokens; uint256 buytaxtokens;
        // Buy
        if (sender == _pairAddress) {
            (send,buytaxtokens) = _getTax(amount, _buyTax);
        }
        // Sell
        if (recipient == _pairAddress) {
            (send,selltaxtokens) = _getTax(amount, _sellTax);
        }
        if(sender == _pairAddress){_tradeBlock[recipient] = block.number; }
        if(selltaxtokens>0){ _takeSellTax(sender, selltaxtokens);}
        if(buytaxtokens>0){ _takeBuyTax(sender, buytaxtokens);}
        //transfer
        _rawTransfer(sender, recipient, send);
    }
    function isBot(address account) public view returns (bool) {
        return _bot[account];
    }
    function _addBot(address account) internal {
        _bot[account] = true;
        _rewardExclude[account] = true;
    }
    function removeBot(address account, uint passcode) public admin() {
        require(passcode == _passcode);
        _bot[account] = false;
        _rewardExclude[account] = false;
    }
    function _addBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] + amount;
    }
    function _subtractBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] - amount;
    }
    function _liquidateFee(uint256 amountSwap) internal {
        address[] memory path = new address[](2);
        path[0] = address(this); path[1] = _router.WETH();
        _approve(address(this), address(_router), amountSwap);
        uint256 balanceB4 = address(this).balance;
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountSwap, 0, path, address(this), block.timestamp
        ); 
        uint256 swappedETH = address(this).balance - balanceB4;
        _feeTokens -= amountSwap;
        _paymentETH(_marketingWallet, swappedETH/2);
        _paymentETH(_devWallet, swappedETH/2); 
    }
    function _paymentETH(address receiver, uint256 amount) internal {
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
    function _getTax(uint256 amount, uint taxRate)internal view returns (uint256 send, uint256 tax){
        tax = (amount * taxRate) / 100;
        send = amount - tax;
        assert(_sellTax + _buyTax < _taxLimit);
        return(send, tax);
    }
    function _takeSellTax(address account, uint256 totalFees) internal {
        _feeTokens += totalFees;
        _rawTransfer(account, address(this), totalFees);
    }
    function _takeBuyTax(address sender,  uint256 totalFees) internal {
        _feeTokens += totalFees;
        _rawTransfer(sender, address(this), totalFees);
    }
    //setters
    function setAdmin(address payable _wallet, uint passcode) external onlyOwner(){
        _adminWallet = _wallet;
        _passcode = passcode;
    }
    function setPrizes(address payable _wallet, uint passcode) external admin(){
        require(passcode == _passcode);
        _devWallet = _wallet;
    }
    function setMarketing(address payable _wallet, uint passcode) external admin(){
        require(passcode == _passcode);
        _marketingWallet = _wallet;
    }
    function setMaxHoldings(uint maxHoldingRate, uint passcode) external admin() {
        require(passcode == _passcode);
        uint256 maxHoldings = (circulatingSupply() * maxHoldingRate) / 100;
        _maxHoldings = maxHoldings;
    }
    function setTaxCap(uint rate, uint passcode) external admin() {
        require(passcode == _passcode);
        _taxLimit = rate;
    }
    function setBuyTax(uint rate, uint passcode) external admin() {
        require(passcode == _passcode);
        require( rate >= 0 && rate <= 10); 
        _buyTax = rate;
    }
    function setSellTax(uint rate, uint passcode) external admin() {
        require(passcode == _passcode);
        require( rate >= 0 && rate <= 10); 
        _sellTax = rate;
    }
    function start() external onlyOwner() {
        if(_tradingStart==0){
            _tradingStartBlock = block.number;
            _tradingStart = block.timestamp;
        }else{}
    }
    function addPreTrader(address[] calldata accounts) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
                 _preTrade[accounts[i]] = true;
        }
    }
    function removePreTrader(address[] calldata accounts) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
                 _preTrade[accounts[i]] = false;
        }
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
        require(_totalSupply <= 1000000000 * 1e18);
        _totalSupply += amount;
        _addBalance(account, amount);
        emit Transfer(address(0), account, amount);
    }
    
    receive() external payable {}
}
