// SPDX-License-Identifier: MIT License
//funding moves from vault to our funding pools
//_totalCurrentAccount is current account (2 ways in[from vault & repayments], 1 way out [funding])
//_totalFundingFromVault tracks how much we have our side
//_totalFundingPaidout tracks whats currently out in project pools (* funding rate = totalRepaymentsDue)
//_totalFundingRepaid tracks whats been paid back, diffrence with above = whats owed by projects)..unrelated to curr acc
//keep track of Total Funded: per day, week, month using timestamp ranges as keys
//keep track of Total Repaid: per day, week, month using ""
//only manager can fund projects except those marked

pragma solidity ^0.8.4;
import "./kickstart.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KickStartAI is Ownable {
    modifier manager(){
		require(msg.sender == _managerWallet);
		_;
	}
    modifier noReentrant() {
        require(!locked, "No re-entrancy");
        locked = true;
        _;
        locked = false;
    }
    uint public _fundingRate = 120;
    uint public globalLoanCount;
    uint256 public _totalFundingFromVault;
    uint256 public _totalFundingRepaid;
    uint256 public _totalFundingPaidout;
    uint256 public _totalFundingPaidoutWallets;
    uint256 public _totalFundingRepaidWallets;
    uint256 public _totalLoansPaidout;
    uint256 public _totalLoansRepaid;
    uint256 public _totalLoansRepaidWallets;
    uint256 public _totalProceedsWithdrawn;
    uint256 public _totalCurrentAccount;
    uint256 public _totalDividentsAvailable;
    uint256 public _minHoldings;
    uint256 public _minimumFunding;
    address public _managerWallet;
    address public _KickStartAIVaultLP;
    address public _KickStartAIVaultFXD;
    address payable public tokenAddress;
    KickStartToken private token;//Token Contract
    bool internal locked;
    mapping(uint256 => uint256) public _totalFundingTerm;
    mapping(uint256 => uint256) public _totalFundingRepaidTerm;
    mapping(uint256 => uint256) public _totalLoansTerm;
    mapping(uint256 => uint256) public _totalLoanRepaidTerm;
    mapping(address => address[]) myfundedProjects;
    mapping(address => address[]) myloanedProjects;
    address[] clubFundedProjects;
    address[] crowdFundedProjects;
    address[] allFundedProjects;
    address[] allFundingRequests;
    address[] allLoanRequests;
    address[] allLoanedProjects;
    address[] clubLoanedProjects;
    address[] walletLoanedProjects;

    event RepaidWithLove(address indexed project, address indexed receiver, uint256 amount, uint256 balance);
    event LiquidityFunded(address indexed project, address indexed funder, uint256 funded, uint256 owed);
    event projectRepaid(address indexed project, uint256 amount, address indexed repayer, uint indexed what);
    event projectFunded(address indexed project, uint256 funded, uint256 due);
    event projectLoaned(address indexed project, uint256 loaned, uint256 due);
    event bookmarked(address indexed owner, address indexed project, bool indexed truefalse);
    
    constructor(address payable _tokenAdd) {
        token = KickStartToken(_tokenAdd);
        tokenAddress = _tokenAdd;        
    }
    mapping(address => projectStruct) projectPools;
    mapping(address => uint[]) projectLoans;
    mapping(uint => loanStruct) loanPools;
    mapping(address => bkmStruct) mybookmarkIndex;
    mapping(address => mapping(address => uint)) myaddytocountMap;
    //save bookmarks in array..this is my publicly readable list of projects i bookmarked
    mapping(address => address[]) mybookmarks;
    mapping(address => mapping(uint => bookmarkInfo)) bookmarkings;
    mapping(address => uint) mycounter;
    struct projectStruct{
        string name;
        string website;
        string telegram;
        string icon_url;
        uint fundType;
        uint requestState;//0 default, 1 approved, 2 denied
        uint256 amount;
        uint256 due;
        uint256 repaid;
        uint256 tokensAdded;
        uint256 managerstamped;//time
        uint256 fundingTime;//time
        address owner;
        address pairAddr;
        address routerReq;
        address factoryReq;
        address liquidityAddr;//returned on funding call
        mapping(address => walletDetail) walletFunding;//individual funders
    }
    struct loanStruct{
        string name;
        string website;
        string telegram;
        string icon_url;
        uint fundType;
        uint requestState;//0 default, 1 approved, 2 denied
        uint256 collateralTokens;
        uint256 amount;
        uint256 due;
        uint256 repaid;
        uint256 managerstamped;//time
        uint256 fundingTime;//time
        address owner;
        address project;
        address receiverWallet;
        address collateralAddress;//address of lp tokens used as collateral
        mapping(address => walletDetail) walletLoaning;//individual funders
    }
    struct walletDetail{
        uint256 due;
        uint256 repaid;
    }
    struct bookmarkInfo{
        bool marking;
        address project;
    }
    struct bkmStruct{
        mapping(address => bool) mark;
    }
    //Fund Fair Launch Project X
    //Cant use Factory and Router & project addy to creat LP ourselves, 
    //this would require requesting project to mint tokens and send to us, cumbersome
    function fundProjectX(address _project, uint256 amountFunded) public payable noReentrant {
        require(token.balanceOf(msg.sender)  >= _minHoldings,"insufficient KickStartAI tokens to use platform");
        require(amountFunded <= projectPools[_project].amount / 50,"exceeds limit");
        require(projectPools[_project].requestState == 1, "funding declined");
        require(projectPools[_project].due <= (projectPools[_project].amount * _fundingRate) / 100,"already funded");
        //update project info
        projectPools[_project].fundingTime = block.timestamp;
        projectPools[_project].due = (amountFunded * _fundingRate) / 100;
        if(projectPools[_project].fundType == 1){
            require(_totalCurrentAccount >= amountFunded,"our funding wallet is dry");
            _totalCurrentAccount -= amountFunded;
            _totalFundingPaidout += amountFunded;//one way tally
        }else{
            require(msg.value == amountFunded,"your funding wallet is low");
            _totalFundingPaidoutWallets += amountFunded;//one way tally
            //save wallet/self in project struct
            projectPools[_project].walletFunding[msg.sender].due += (amountFunded * _fundingRate) / 100;
            myfundedProjects[msg.sender].push(_project);
        }
        //update project info
        projectPools[_project].fundingTime = block.timestamp;
        projectPools[_project].due += (amountFunded * _fundingRate) / 100;
        //finally, liquidity only added once full raise is reached
        if(projectPools[_project].due == projectPools[_project].amount * _fundingRate){
            (bool success, bytes memory result) = _project.call{value: amountFunded}(abi.encodeWithSignature("receiveFunding(address,address,address,uint256)",projectPools[_project].routerReq,projectPools[_project].factoryReq,_KickStartAIVaultLP,projectPools[_project].tokensAdded));
            require(success, "call failed");
            address liquidityAddr = abi.decode(result, (address));
            projectPools[_project].liquidityAddr = liquidityAddr;
        }
        //update trackers
        _totalFundingTerm[block.timestamp] += amountFunded;
        emit projectFunded(_project,amountFunded,(amountFunded * _fundingRate) / 100);
    }
    //Loan Processing: club and wallet combined
    function loanProjectX(address _project, uint requestID) public payable noReentrant() {
        uint256 amountLoaned = loanPools[requestID].amount;
        require(loanPools[requestID].requestState == 1, "loan declined");
        require(loanPools[requestID].managerstamped == 0,"already granted loan");
        require(loanPools[requestID].due <= (loanPools[requestID].amount * _fundingRate) / 100,"already funded");
        if(loanPools[requestID].fundType == 1){
            require(_totalCurrentAccount >= amountLoaned,"our wallet is dry");
            require(loanPools[requestID].fundType == 1,"wallet loan requested");
            _totalCurrentAccount -= amountLoaned;
        }else{
            require(msg.value >= amountLoaned,"topup your wallet balance");
            require(loanPools[requestID].fundType == 2,"club loan requested");
            //save wallet/self in project struct
            loanPools[requestID].walletLoaning[msg.sender].due += (amountLoaned * _fundingRate) / 100;
            myloanedProjects[msg.sender].push(_project);
        }
        //send transaction: deposit function
        _paymentETH(loanPools[requestID].receiverWallet, amountLoaned);//amount not balance
        //update project info
        loanPools[requestID].fundingTime = block.timestamp;
        loanPools[requestID].due = (amountLoaned * _fundingRate) / 100;
        _totalLoansPaidout += amountLoaned;//one way tally
        //consider use of date combinations as unique key: yearmonthday
        _totalLoansTerm[block.timestamp] += amountLoaned;
        emit projectLoaned(_project,amountLoaned,(amountLoaned * _fundingRate) / 100);
    }
    //withdrawal
    function withdrawProceeds(address _project, uint256 _amount) public noReentrant {
        uint256 _due = projectPools[_project].walletFunding[msg.sender].due;
        uint256 _repaid = projectPools[_project].walletFunding[msg.sender].repaid;
        require(_due > 0,"no liquidity provided");
        require(_repaid < _due,"all paid");
        require(_amount + _repaid <= _due,"excessive");
        require(_amount <= projectPools[_project].repaid,"no liquidity to process, wait for more repayments");
        uint256 balance = _due - _repaid;
        if(balance > 0){
            _paymentETH(msg.sender, _amount);//amount not balance
            _totalProceedsWithdrawn += _amount;//one way tally
            projectPools[_project].walletFunding[msg.sender].repaid += _amount;
        }
        emit RepaidWithLove(_project, msg.sender, _amount, balance);
    }
    //repayment from projects funded
    //you can keep paying in pepertuity beyond whats due
    function repayProjectFunding(address _project) public payable noReentrant {
        require(msg.value > 0,"bruh");
        projectPools[_project].repaid += msg.value;
        if(projectPools[_project].fundType == 1){
            _totalFundingRepaid += msg.value;//one way tally
            _totalCurrentAccount += msg.value;
            //log profits separately so they are sent to vault as dividents
            //this keeps it simple, dividents for money the club spinned, ignores all other money
            //vault is open periodically then closes, so only current depositors get these dividents
            uint256 initial = (msg.value * 100)/ _fundingRate;
            uint256 profits = msg.value - initial;
            _totalDividentsAvailable += profits;
        }else{
            _totalFundingRepaidWallets += msg.value;//one way tally - to individual funders
        }
        _totalFundingRepaidTerm[block.timestamp] += msg.value;
        emit projectRepaid(_project, msg.value, msg.sender, 1);
    }    
    //when i finally repay the whole loan, reset fundType to 0 so project can borrow again
    function repayProjectLoan(address _project, uint request) public payable noReentrant {
        require(msg.value > 0,"bruh");
        loanPools[request].repaid += msg.value;
        //if funder was club
        if(loanPools[request].fundType == 1){
            _totalLoansRepaid += msg.value;//one way tally
            _totalCurrentAccount += msg.value;
            uint256 initial = (msg.value * 100)/ _fundingRate;
            uint256 profits = msg.value - initial;
            _totalDividentsAvailable += profits;
        }else{
            _totalLoansRepaidWallets += msg.value;//one way tally - to individual funders
        }
        if(loanPools[request].repaid >= loanPools[request].due){
            loanPools[request].fundType = 0;//reset eligibility
        }
        _totalLoanRepaidTerm[block.timestamp] += msg.value;
        emit projectRepaid(_project, msg.value, msg.sender, 2);
    }
    //only owner wallet of given address can request funding
    //only owner can withdraw tokens from lock contract after repayment. owner can mannually extend lock too
    //funding type:  1 - club funded package requested, 2 - wallet funded package requested
    function requestFunding(address project, address router, address factory, uint fundingtype, uint256 amountETH, uint256 tokens, string memory name, string memory website, string memory telegram, string memory icon_128px_url)public {
        require(address(project) != address(0),"Token cannot be address 0");
        require(projectPools[project].amount == 0,"already requested");
        require(amountETH > _minimumFunding,"funding ask below min");
        require(fundingtype >= 1 && fundingtype <= 2,"min 0 max 2");
        (bool success, bytes memory result) = project.call(abi.encodeWithSignature("owner()"));
        require(success, "owner fetch failed");
	    address owner = abi.decode(result, (address));
        if(owner == address(0) || owner != msg.sender){	revert("not owner");	}
        //proceed
        projectPools[project].name = name;
        projectPools[project].website = website;
        projectPools[project].telegram = telegram;
        projectPools[project].icon_url = icon_128px_url;
        projectPools[project].amount = amountETH;
        projectPools[project].tokensAdded = tokens;
        projectPools[project].fundType = fundingtype;
        projectPools[project].owner = owner;
        projectPools[project].factoryReq = factory;
        projectPools[project].routerReq = router;
        //array of funding requesters
        allFundingRequests.push(project);
    }
    //request loan using LP tokens as collateral
    //funding type is chosen by project owner: club funded or wallet funded [1|2]
    //consider changing from owner() to manager() as requester
    function requestLoan(address project, address receiver, address LPaddress, uint fundingtype, uint256 amountETH, string memory name, string memory website, string memory telegram, string memory icon_128px_url)public {
        require(address(project) != address(0),"cannot be address 0");
        uint index = projectLoans[project].length;
        uint mylastRequest = projectLoans[project][index];
        if(mylastRequest > 0){mylastRequest = projectLoans[project].length - 1;}
        //cant borrow more if last loan isnt repaid fully:
        require(loanPools[mylastRequest].repaid >= loanPools[mylastRequest].due,"pay up to borrow again");
        require(loanPools[mylastRequest].fundType == 0,"you already requested, wait approval");
        require(amountETH > 0.5 ether,"funding ask below min");
        require(fundingtype >= 1 && fundingtype <= 2,"min 1 max 2");
        (bool success, bytes memory result) = project.call(abi.encodeWithSignature("owner()"));
        require(success, "owner fetch failed");
	    address owner = abi.decode(result, (address));
        if(owner == address(0) || owner != msg.sender){	revert("not owner");	}
        //proceed
        loanPools[globalLoanCount].name = name;
        loanPools[globalLoanCount].website = website;
        loanPools[globalLoanCount].telegram = telegram;
        loanPools[globalLoanCount].icon_url = icon_128px_url;
        loanPools[globalLoanCount].amount = amountETH;
        loanPools[globalLoanCount].fundType = fundingtype;
        loanPools[globalLoanCount].receiverWallet = receiver;
        loanPools[globalLoanCount].project = project;
        loanPools[globalLoanCount].owner = owner;
        loanPools[globalLoanCount].collateralAddress = LPaddress;
        //array of requesters & array of project's loan requests. spam protected above: "pay up to borrow again"
        allLoanRequests.push(project);
        globalLoanCount ++;
    }
    //changing funding state is allowed: 1 - accepted, 2 declined
    //saved accepted projects in arrays: club funded, wallet funded
    //if club managers think they like the project more they can poach it
    function stampFundingRequest(address project, bool stamp, bool poach) public manager(){
        require(address(project) != address(0),"Token cannot be address 0");
        if(stamp){
            projectPools[project].requestState = 1;
            //update projects that got club funding
            if(projectPools[project].fundType==1 || poach){
                clubFundedProjects.push(project);
            }else{
                crowdFundedProjects.push(project);
            }
            allFundedProjects.push(project);
        }else{
            projectPools[project].requestState = 2;
        }
        projectPools[project].managerstamped = block.timestamp;
    }
    //same as above for loans
    //if club managers think they like the project more they can poach it
    function stampLoanRequest(address project, uint request, bool stamp, bool poach) public manager(){
        require(address(project) != address(0),"Token cannot be address 0");
        if(stamp){
            loanPools[request].requestState = 1;
            if(loanPools[request].fundType==1 || poach){
                clubLoanedProjects.push(project);
            }else{
                walletLoanedProjects.push(project);
            }
            allLoanedProjects.push(project);
        }else{
            loanPools[request].requestState = 2;
        }
        projectLoans[project].push(request);
        loanPools[request].managerstamped = block.timestamp;
    }
    //bookmark projects, refresh list/arry on unbookmarking
    function bookmarkProject(address _address) public{
        require(msg.sender != address(0));
        require(token.balanceOf(msg.sender) >= _minHoldings, "buy more tokens");
        if(!mybookmarkIndex[msg.sender].mark[_address]){
            mybookmarks[msg.sender].push(_address);
            mybookmarkIndex[msg.sender].mark[_address] = true;
            mycounter[msg.sender] += 1;
            bookmarkings[msg.sender][mycounter[msg.sender]].marking = true;
            myaddytocountMap[msg.sender][_address] = mycounter[msg.sender];
            emit bookmarked(msg.sender, _address, true);
        }else{//bookmarked, so unmark and refresh array
            mybookmarkIndex[msg.sender].mark[_address] = false;
            uint counterID = myaddytocountMap[msg.sender][_address];
            bookmarkings[msg.sender][counterID].marking = false;
            //iterate whole array and save bookmarked only
            //for each item between 0 and current Counter
            //> check if bookmarked and add into array mybookmarks[msg.sender]
            //> delete that array first
            delete mybookmarks[msg.sender];
            for (uint i = 0; i < mycounter[msg.sender]; i++) {
                //save project in recycled array if marked as bookmarked
                if(bookmarkings[msg.sender][i].marking){
                    address projectAddr = bookmarkings[msg.sender][i].project;
                    mybookmarks[msg.sender].push(projectAddr);
                }
                if(i == mycounter[msg.sender]){break;}
            }
            emit bookmarked(msg.sender, _address, true);
        }
    }
    function getbookmarkOnProject(address _address) public view returns(bool marking){
        return mybookmarkIndex[msg.sender].mark[_address];
    }
    //manager deposits funding from vault
    function depositFundingCapital() public payable {
        require(msg.value > 0,"bruh");
        _totalFundingFromVault += msg.value;
        _totalCurrentAccount += msg.value;
    }
    //manager repays funding to vault
    function repayFundingCapital(uint256 _amount) public payable manager noReentrant{
        require(_amount > 0, "manager bruh");
        require(_amount <= _totalFundingFromVault, "exceeds funding");
        (bool success,) = _KickStartAIVaultFXD.call{value: _amount}(abi.encodeWithSignature("receiveCapitalRepayment()"));
        require(success, "repayment failed");
        _totalFundingFromVault -= _amount;
    }
    //pay taxes to parent contract
    function sendDividents() public payable manager{
        require(_totalDividentsAvailable > 0,"manager bruh");
        (bool success,) = tokenAddress.call{value: _totalDividentsAvailable}(abi.encodeWithSignature("addDividentETH()"));
        require(success, "Failed to send dividents to vault");
        _totalDividentsAvailable -= _totalDividentsAvailable;
    }
    function _paymentETH(address receiver, uint256 amount) internal {
        (bool sent, ) = receiver.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
    //if requester is project owner & project addr & lp addr matches, return true to give permission to assign withdrawer
    function mapPermissions(address owner, address _projectAddr, address _liquidityAddr) public view returns(bool pass){
        require(msg.sender == _KickStartAIVaultLP,"bruh");
        require(_projectAddr != address(0) && _liquidityAddr != address(0),"not zero address");
        if(owner == projectPools[_projectAddr].owner && _liquidityAddr == projectPools[_projectAddr].liquidityAddr){
            pass = true;
        }
        return pass;
    }
    /////////////////////////////////////////////////////////////////////////////////////////////////
    //in future add: for all below array fetches, an iterative function to fetch from index x to y...
    //get funded projects - all approved for funding
    function getFundedProjects() public view returns(address[] memory){
        return allFundedProjects;
    }
    //get clubfunded projects - only those who arent fully funded
    function getClubFundedProjects() public view returns(address[] memory){
        return clubFundedProjects;
    }
    //get crowdfunded projects - only those who arent fully funded
    function getCrowdFundedProjects() public view returns(address[] memory){
        return crowdFundedProjects;
    }
    //get all requests - admin call
    function getAllFundingRequests() public view returns(address[] memory){
        return allFundingRequests;
    }
    function getAllLoanRequests() public view returns(address[] memory){
        return allLoanRequests;
    }
    //get all loaned projects
    function getLoanedProjects() public view returns(address[] memory){
        return allLoanedProjects;
    }
    //get club loaned projects
    function getClubLoanedProjects() public view returns(address[] memory){
        return clubLoanedProjects;
    }
    //get crowd loaned projects
    function getCrowdLoanedProjects() public view returns(address[] memory){
        return walletLoanedProjects;
    }
    //get a projects loan history
    function getProjectsLoanHistory(address _project) public view returns(uint[] memory){
        return projectLoans[_project];
    }
    //get list of projects funded by my wallet  
    function getMyFundedProjects(address _wallet) public view returns(address[] memory){
        return myfundedProjects[_wallet];
    }
    //get list of loans issued by my wallet
    function getMyLoansProjects(address _wallet) public view returns(address[] memory){
        return myloanedProjects[_wallet];
    }
    //get funding profile
    function getProfileILL(address project) public view returns(string memory name, string memory website, string memory telegram, string memory url, address owner, uint funder, uint requestState){
        return(projectPools[project].name, projectPools[project].website, projectPools[project].telegram, projectPools[project].icon_url, projectPools[project].owner, projectPools[project].fundType, projectPools[project].requestState);
    }
    function getLaunchAmnts(address project) public view returns(uint256 amount, uint256 due,  uint256 repaid, uint256 fundingTime, uint256 managerstamped, uint256 tokensAdded){
        return(projectPools[project].amount, projectPools[project].due, projectPools[project].repaid, projectPools[project].fundingTime, projectPools[project].managerstamped, projectPools[project].tokensAdded);
    }
    function getLaunchAddrs(address project) public view returns(address pair, address router, address factory){
        return(projectPools[project].pairAddr, projectPools[project].routerReq, projectPools[project].factoryReq);
    }
    function getClubFundingProfile(address project)public view returns(uint256 _due, uint256 _repaid, uint256 _time){
        require(projectPools[project].fundType == 1, "not club financed");
        return(projectPools[project].due, projectPools[project].repaid, projectPools[project].fundingTime);
    }
    function getWalletFundingProfile(address project)public view returns(uint256 _due, uint256 _repaid, uint256 _time){
        require(projectPools[project].fundType == 2, "not wallet financed");
        return(projectPools[project].walletFunding[msg.sender].due, projectPools[project].walletFunding[msg.sender].repaid, projectPools[project].fundingTime);
    }
    function getProfileOPL(uint loanID) public view returns(string memory name, string memory website, string memory telegram, string memory url, address owner, uint requestState, uint256 managerstamped){
        return(loanPools[loanID].name, loanPools[loanID].website, loanPools[loanID].telegram, loanPools[loanID].icon_url, loanPools[loanID].owner, loanPools[loanID].requestState, loanPools[loanID].managerstamped);
    }
    function getLoanAmnts(uint requestID)public view returns(uint256 fundedTime, uint256 amount, uint256 _due, uint256 _repaid, uint256 collateral, address collateralAddy, address receiverWallet){
        return(loanPools[requestID].fundingTime, loanPools[requestID].amount, loanPools[requestID].due, loanPools[requestID].repaid, loanPools[requestID].collateralTokens, loanPools[requestID].collateralAddress, loanPools[requestID].receiverWallet);
    }
    function getProfileAddy(uint loanID) public view returns(address projectAddr){
        return(loanPools[loanID].project);
    }
    function getWalletLoanProfile(uint requestID)public view returns(uint256 _due, uint256 _repaid, uint256 _time){
        return(loanPools[requestID].walletLoaning[msg.sender].due, loanPools[requestID].walletLoaning[msg.sender].repaid, loanPools[requestID].fundingTime);
    }
    
    //according to DEXT Live New Pairs Bot(eth) a telegram bot that tracks all new pairs live
    //from 15 december to 22 december there were 918 new pairs
    //on 22 december there were 70 new pairs
    function getFundingForTerm(uint256 timestampStart, uint256 timestampTo) public view returns (uint256 sum){
        for (uint i = timestampStart; i < timestampTo; i++) {
            //sum the funding
            sum += _totalFundingTerm[i];
            if(i == timestampStart-1){break;}
        }
        return(sum);
    }
    function getRepaidForTerm(uint256 timestampStart, uint256 timestampTo) public view returns (uint256 sum){
        for (uint i = timestampStart; i < timestampTo; i++) {
            //sum the repaid funding
            sum += _totalFundingRepaidTerm[i];
            if(i == timestampStart-1){break;}
        }
        return(sum);
    }
    //setters
    function setmanager(address _wallet) external onlyOwner(){
        _managerWallet = _wallet;
    }
    function setFixedTermVault(address payable _vaultFixedTerm) external manager(){
        require(_KickStartAIVaultFXD == address(0),"already set");
        _KickStartAIVaultFXD = _vaultFixedTerm;
    }
    function setLiquidityVault(address payable _vaultLiquidity) external manager(){
        require(_KickStartAIVaultLP == address(0),"already set");
        _KickStartAIVaultLP = _vaultLiquidity;
    }
    function setLiquidityFundRate(uint _rate) external manager(){
        require(_rate >= 100 && _rate <=130);
        _fundingRate = _rate;
    }
    function setMinHoldings(uint256 _minTokens) external manager(){
        require(_minTokens > 1000 * 1e18);
        _minHoldings = _minTokens;
    }
    function setMinFunding(uint256 _ethWEI) external manager(){
        require(_ethWEI > 0);
        _minimumFunding = _ethWEI;
    }
    
    receive() external payable {}
}
