// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.5;

contract TinFoil{

    string constant public name = "TinFoil";              
    string constant public symbol = "TIN"; 
    uint8 constant public decimals = 18;
    uint constant public totalSupply = 10 ** 27;     // total, constant, supply of atoms
    uint constant private initialShinyLength = 10 ** 26;
    uint8 constant private bigLittleRatio = 100;     // ratio of big bounty : little bounty 
    uint32 constant private TIME_TO_HALF = 31536000;    // one year = 31536000


    /** An owner.
    Stores a user's address, TinFoil balance, and length of Shiny Roll owned, 
    the amount of TinFoil they are allowing each other user,
    as well as the total length of Shiny Roll owned by users in the subheap in Owner[] heap
    rooted at this owner.
    */
    struct Owner {
        address owner; // the corresponding address
        string nickname;
        uint balance; // the user's TinFoil balance
        uint length; // the user's length of the Shiny Roll        
        uint subtreeLengthSum; // the sum of the lengths of all nodes in the subtree
        uint investments; // sum of investments into Shiny Roll
        uint winnings; // sum of user's lifetime winnings from the Shiny Roll
    }

    Owner[] private heap; // the userbase is stored in a max heap data structure, keyed by subtreeLengthSum
    mapping(address => uint) private indexOf; // maps addresses to corresponding index in heap (defaults to 0)
    mapping(address => mapping(address => uint)) private allowed; // how many atoms users may withdraw from one another
    uint private lastRollTime; // stores the time of the last roll

    event Transfer(address indexed _from, address indexed _to, uint _value);
    event Approval(address indexed _owner, address indexed _spender, uint _value);
    event Invested(address indexed investor, uint amount);
    event BountyWon(address indexed BigWinner, uint BigBounty, 
                    address indexed LittleWinner, uint LittleBounty);


    /// Not enough TinFoil in balance. Requested `requested`,
    /// but only `available` available.
    error InsufficientTinFoil(uint requested, uint available);

    /// Not enough TinFoil in allowance. Requested `requested`,
    /// but only `approved` available.
    error TransferNotApproved(uint requested, uint approved);

    /// Nickname `attempt` is invalid. Nicknames must be less than 25 characters long and
    /// cannot spell the word 'treasury', ignoring case.
    error InvaldNickname(string attempt);

    /// The little bounty has already been claimed for this block.
    error BountyAlreadyClaimed();


    constructor() {
        heap.push(Owner(address(this), "TREASURY", totalSupply * 4 / 5, 
                        initialShinyLength, initialShinyLength, 0, 0));
        indexOf[address(this)] = 0;
        heap.push(Owner(msg.sender, "DEVS", totalSupply / 5, 0, 0, 0, 0));
        indexOf[msg.sender] = 1;

        lastRollTime = block.timestamp;
    }


    ////////// PUBLIC FUNCTIONS //////////
    function balanceOf(address owner) public view returns (uint balance) {
        uint index = indexOf[owner];
        if (index == 0 && owner != address(this)) {
            return 0;
        }
        return heap[index].balance;
    }    

    function transfer(address to, uint value) public returns (bool success) {
        if (balanceOf(msg.sender) < value) {
            revert InsufficientTinFoil(value, balanceOf(msg.sender));
        }

        uint fromIndex = getIndex(msg.sender);
        uint toIndex = getIndex(to);
        heap[fromIndex].balance -= value;
        heap[toIndex].balance += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) public returns (bool success) {
        if (balanceOf(from) < value) {
            revert InsufficientTinFoil(value, balanceOf(from));
        }
        if (allowance(from, msg.sender) < value) {
            revert TransferNotApproved(value, allowance(from, msg.sender));
        }

        uint fromIndex = getIndex(from);
        uint toIndex = getIndex(to);
        heap[fromIndex].balance -= value;
        heap[toIndex].balance += value;
        allowed[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint remaining) {
        return allowed[owner][spender];
    }

    function approve(address spender, uint value) public returns (bool success) {
        allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }


    // total length of Shiny Roll
    function ShinyRollLength() public view returns (uint length) {
        return heap[0].subtreeLengthSum;
    }

    // length of owner's share of Shiny Roll
    function lengthOf(address owner) public view returns (uint length) {
        uint index = indexOf[owner];
        if (index == 0 && owner != address(this)) {
            return 0;
        }
        return heap[index].length;
    }

    function investmentsOf(address owner) public view returns (uint investments) {
        uint index = indexOf[owner];
        if (index == 0 && owner != address(this)) {
            return 0;
        }
        return heap[index].investments;
    }

    function winningsOf(address owner) public view returns (uint winnings) {
        uint index = indexOf[owner];
        if (index == 0 && owner != address(this)) {
            return 0;
        }
        return heap[index].winnings;
    }

    // invest in the Shiny Roll. Returns success iff investment successful.
    function invest(uint investment) public returns (bool success) {
        transfer(address(this), investment);

        uint index = getIndex(msg.sender);
        // apply multiplier to investment
        uint value = (investment * (ShinyRollLength() - lengthOf(msg.sender))) / initialShinyLength;
        heap[index].length += value;
        uint current = index;
        while (true) {
            heap[current].subtreeLengthSum += value;
            if (current == 0) {
                break; 
            }
            current = (current - 1) / 2;
        }
        heap[index].investments += investment;
        emit Invested(msg.sender, value);
        emit Transfer(msg.sender, address(this), value);
        return true;
    }

    // returns big bounty at time of evaluation
    function bigBounty() public view returns (uint big) {
        uint t = block.timestamp - lastRollTime; // time since last roll

        return heap[0].balance - (TIME_TO_HALF * heap[0].balance) / (t + TIME_TO_HALF);
    }

    // returns little bounty at time of evaluation
    function littleBounty() internal view returns (uint little) {
        return bigBounty() / bigLittleRatio;
    }

    // claim the little bounty. Returns true iff msg.sender wins. Transfers both bounties to their winners.
    function claimLittleBounty() public returns (bool success) {
        (uint big, uint little) = (bigBounty(), littleBounty());
        if (big == 0) {
            revert BountyAlreadyClaimed();
        }
        
        uint random = uint(keccak256(abi.encodePacked(
            msg.sender, block.timestamp, 
            block.difficulty, blockhash(block.number-1)))) % ShinyRollLength();
        address bigWinner = pickBigWinner(random);

        lastRollTime = block.timestamp;

        allowed[address(this)][msg.sender] = little + big;
        transferFrom(address(this), msg.sender, little);
        transferFrom(address(this), bigWinner, big);
        heap[indexOf[bigWinner]].winnings += big;
        emit BountyWon(bigWinner, big, msg.sender, little);
        return true;
    }

    // set your own nickname (under 25 chararacters long)
    function setNickname(string calldata nickname) public returns (bool success) {
        uint index = getIndex(msg.sender);
        if (stringLength(nickname) > 24) {
            revert InvaldNickname(nickname);
        }
        heap[index].nickname = nickname;
        return true;
    }

    // get an addresses' nickname
    function nicknameOf(address user) public view returns (string memory nickname) {
        uint index = indexOf[user];
        if (index == 0 && user != address(this)) {
            return "";
        }
        return heap[index].nickname;
    }


    ////////// INTERNAL FUNCTIONS //////////
    // return index of account in heap. If user isn't in heap, append them and return their new index.
    function getIndex(address account) internal returns (uint index) {
        uint i = indexOf[account];
        if (i == 0 && account != address(this)) {
            i = heap.length;
            heap.push(Owner(account, "", 0, 0, 0, 0, 0));
            indexOf[account] = i;
        }
        return i;
    }

    // returns owner of a given position, in range [0, ShinyRollLength), on the Shiny Roll
    function pickBigWinner(uint position) internal view returns (address winner) {
        uint index = 0;
        while (true) {
            uint left = 2 * index + 1;
            uint right = 2 * index + 2;

            // node at index has no children
            if (left >= heap.length) {
                return heap[index].owner;
            }
            // node at index has only a left child
            if (right >= heap.length) {
                return position < heap[left].length ? heap[left].owner : heap[index].owner;
            }
            // node at index has two children
            if (position < heap[left].subtreeLengthSum) {
                index = left;
            } else if (position < heap[left].subtreeLengthSum + heap[index].length) {
                return heap[index].owner;
            } else {
                index = right;
                position -= heap[left].subtreeLengthSum + heap[index].length;
            }
        }
    }

    // return length of a string
    function stringLength(string memory str) internal pure returns (uint length) {
        uint i=0;
        bytes memory string_rep = bytes(str);
        while (i<string_rep.length) {
            if (string_rep[i]>>7==0) {
                i+=1;
            } else if (string_rep[i]>>5==bytes1(uint8(0x6))) {
                i+=2;
            } else if (string_rep[i]>>4==bytes1(uint8(0xE))) {
                i+=3;
            } else if (string_rep[i]>>3==bytes1(uint8(0x1E))) {
                i+=4;
            } else {
                //For safety
                i+=1;
            }

            length++;
        }
    }
}
