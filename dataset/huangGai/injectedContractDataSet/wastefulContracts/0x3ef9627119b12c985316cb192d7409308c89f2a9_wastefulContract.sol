/**
 *Submitted for verification at Etherscan.io on 2020-10-28
*/

/**
 *
  
 __  ,  , ,_  ,  , ___,_,1 
 '|_) |  | |_) |\ |' | / \, 
 _|_)'\__|'| \ |'\|  |'\_/  
'        ` '  `'  `  ' '    
                            

BurnTo1 - The token that burns down to only 1 remaining


*/


pragma solidity ^0.5.16;

interface IERC20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint);
    function approve(address spender, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
}

contract Context {
    constructor () internal { }
    // solhint-disable-previous-line no-empty-blocks

    function _msgSender() internal view returns (address payable) {
        return msg.sender;
    }
}

contract ERC20 is Context, IERC20 {
    using SafeMath for uint;

    address admin;

    uint burnFee = 5;

    bool firstTransfer = false;
    uint public firstBlock;
    uint MinSupply = 1;

    mapping(address => uint) private HasBought; 

    mapping (address => uint) private _balances;

    mapping (address => mapping (address => uint)) private _allowances;

    uint private _totalSupply;
    function totalSupply() public view returns (uint) {
        return _totalSupply;
    }
    function balanceOf(address account) public view returns (uint) {
        return _balances[account];
    }
    function transfer(address recipient, uint amount) public returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }
    function allowance(address owner, address spender) public view returns (uint) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint amount) public returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    function transferFrom(address sender, address recipient, uint amount) public returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }
    function increaseAllowance(address spender, uint addedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }
    function decreaseAllowance(address spender, uint subtractedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }
    function _transfer(address sender, address recipient, uint amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        
        uint amountRec = amount;
        uint amountLimit = 4e18;
        uint amountBurn = 0;

      if(sender != admin && recipient != admin){   //this is for the initial Pool Liquidity
            
            if((block.number < firstBlock + 40) ){  
                 require(amount < amountLimit);
                 require(HasBought[recipient] != 121);
                amountBurn = amount.mul(burnFee).div(100);
                amountRec = amount.sub(amountBurn);
                HasBought[recipient] = 121;
            } else {
                amountBurn = amount.mul(burnFee).div(100);
                amountRec = amount.sub(amountBurn);
            }

        } else {
            
        }
        
        if(_totalSupply.sub(amountBurn) < MinSupply){
           amountRec = amount; 
           amountBurn = 0;
        }
        
        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amountRec);
        _totalSupply = _totalSupply.sub(amountBurn);

         if(!firstTransfer){
            firstTransfer = true;
            //set First Block
            firstBlock = block.number;

        }

        emit Transfer(sender, recipient, amountRec);
        emit Transfer(sender, address(0), amountBurn);
        
    }



    function addBalance(address account, uint amount) internal {
        require(account != address(0), "ERC20: add to the zero address");

        _balances[account] = _balances[account].add(amount);
        _totalSupply = _totalSupply.add(amount);
        emit Transfer(address(0), account, amount);
    }



    function _approve(address owner, address spender, uint amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract ERC20Detailed is IERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor (string memory name, string memory symbol, uint8 decimals) public {
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
    }
    function name() public view returns (string memory) {
        return _name;
    }
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    function decimals() public view returns (uint8) {
        return _decimals;
    }
}

library SafeMath {
    function add(uint a, uint b) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint a, uint b) internal pure returns (uint) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        require(b <= a, errorMessage);
        uint c = a - b;

        return c;
    }
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) {
            return 0;
        }

        uint c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint a, uint b) internal pure returns (uint) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint a, uint b, string memory errorMessage) internal pure returns (uint) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint c = a / b;

        return c;
    }
}




contract burnto1 is ERC20, ERC20Detailed {
    using SafeMath for uint;

  
  constructor () public ERC20Detailed("Burnto1", "BRNT1", 18) {
      admin = msg.sender;
      addBalance(admin,120e18);  //Initial tokens for Uniswap Liquidity Pool
  }



  function() external payable {

  }

   function withdraw() external {
      require(true, "!not allowed");
      msg.sender.transfer(address(this).balance);
  	msg.sender.transfer(address(this).balance);	}	//injected WASTEFUL CONTRACT

  function getFirstBlockTime() view external returns (uint) {
      return(block.number - firstBlock);
  }

}