pragma solidity ^0.5.0;

import "./Account.sol";
import "./Event.sol";
import "./Ticket.sol";
import "./EventToken.sol";

contract Platform {
    Account accountContract;
    EventToken eventTokenContract;
    Event eventContract;
    Ticket ticketContract;

    event BidCommenced (uint256 eventId);
    event BidPlaced (uint256 eventId, address buyer, uint256 tokenBid);
    event BidBuy (uint256 eventId);
    event TransferToBuyerSuccessful(address to, uint256 amount);

    mapping(address => uint256) sellerDepositedValue;
    address owner;

    // Platform can only exist if other contracts are created first
    constructor(Account accountAddr, EventToken eventTokenAddr, Event eventAddr, Ticket ticketAddr) public {
        accountContract = accountAddr;
        eventTokenContract = eventTokenAddr;
        eventContract = eventAddr;
        ticketContract = ticketAddr;
        owner = msg.sender;
    }

    struct bidInfo {
        uint256 quantity;
        uint256 pricePerTicket;
        uint256 tokenPerTicket;
        uint256 firstIndexForEventBiddings; // For ease of updating bid
    }

    mapping(uint256 => uint256) public eventTopBid; // eventId => topBid
    mapping(uint256 => mapping(uint256 => address[])) public eventBiddings; // eventId => (tokenBid => addressArray) 
    mapping(address => mapping(uint256 => bidInfo)) public addressBiddings; // address => (eventId => bidInfo)

    /* Ensure caller is a buyer */
    modifier isBuyer() {
        require(accountContract.viewAccountState(msg.sender) == accountContract.getUnverifiedStatus(), "You are not a buyer");
        _;
    }

    /*Ensure caller is a verified seller*/
    modifier isOrganiser() {
        require(accountContract.viewAccountState(msg.sender) == accountContract.getVerifiedStatus(),"You are not a verified seller");
        _;
    }

    // list Event on Platform
    function listEvent(string memory title,
        string memory venue,
        uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second,
        uint256 capacity,
        uint256 priceOfTicket,
        address seller) public payable isOrganiser() returns (uint256) {

        // however msg.value here will not be sent to event contract. msg.value at event contract is 0.
        require(msg.value >= calMinimumDeposit(capacity,priceOfTicket) * 1 wei, "Insufficient deposits. Need deposit minimum (capacity * priceOfTicket)/2 * 50000 wei to list event.");

        uint256 newEventId = eventContract.createEvent(title, venue, year, month, day, hour, minute, second, capacity, priceOfTicket, seller);
        sellerDepositedValue[msg.sender] = msg.value;
        return newEventId;
    }

    // Commence bidding for event
    function commenceBidding(uint256 eventId) public {
        require(msg.sender == eventContract.getEventSeller(eventId), "Only seller can commence bidding");
        require(eventContract.getEventBidState(eventId) == Event.bidState.close, "Event already open for bidding");

        eventContract.setEventBidState(eventId, Event.bidState.open);
        emit BidCommenced(eventId);
    }

    // Bid for ticket
    function placeBid(uint256 eventId, uint8 quantity, uint256 tokenBid) public payable isBuyer() {
        require(eventContract.getEventBidState(eventId) == Event.bidState.open, "Event not open for bidding");
        require(quantity > 0, "Quantity of tickets must be at least 1");
        require(quantity <= 4, "You have passed the maximum bulk purchase limit");
        require(msg.value >= eventContract.getEventTicketPrice(eventId) * quantity, "Buyer has insufficient ETH");
        require(eventTokenContract.checkEventTokenOf(msg.sender) >= tokenBid * quantity, "Buyer has insufficient EventTokens");
        
        // Transfer tokenBid & ETH to contract
        if (tokenBid > 0) {
            require(eventTokenContract.checkAllowance(msg.sender, address(this)) >= tokenBid * quantity, "Buyer has not approved sufficient EventTokens");
            eventTokenContract.approvedTransferFrom(msg.sender, address(this), address(this), tokenBid * quantity);
        }
        msg.sender.transfer(msg.value - (eventContract.getEventTicketPrice(eventId) * quantity)); // transfer remaining back to buyer
    
        // Record eventBiddings
        uint256 firstIdx;
        for (uint8 i = 0; i < quantity; i++) {
            eventBiddings[eventId][tokenBid].push(msg.sender);
            if (i == 0) {
                firstIdx = eventBiddings[eventId][tokenBid].length - 1;
            }
        }

        // Record bidInfo for ease of future refund / update 
        bidInfo memory newBidInfo = bidInfo(quantity, eventContract.getEventTicketPrice(eventId), tokenBid, firstIdx);
        addressBiddings[msg.sender][eventId] = newBidInfo;
        
        // Update top bid
        if (tokenBid > eventTopBid[eventId]) {
            eventTopBid[eventId] = tokenBid;
        }
        emit BidPlaced(eventId, msg.sender, tokenBid);
    }

    // Close bidding and transfer tickets to top bidders
    function closeBidding(uint256 eventId) public {
        require(msg.sender == eventContract.getEventSeller(eventId), "Only seller can close bidding");
        require(eventContract.getEventBidState(eventId) == Event.bidState.open, "Event not open for bidding");

        uint256 bidAmount = eventTopBid[eventId];
        uint256 ticketsLeft = eventContract.getEventTicketsLeft(eventId);
        uint256 ticketId = eventContract.getEventFirstTicketId(eventId);

        // Tickets given out starting from top bidders
        while (ticketsLeft != 0) {
            address[] memory bidderList = eventBiddings[eventId][bidAmount];
            for (uint256 i = 0; i < bidderList.length; i++) {
                if (bidderList[i] == address(0)) continue; 

                ticketContract.transferTicket(ticketId, bidderList[i]); 
                ticketId++;
                ticketsLeft--;
                //burnToken()
                if (ticketsLeft == 0) break;
            }
            if (bidAmount == 0) break;
            bidAmount--;
        }

        // TODO: Return unsuccessful bidders
        // returnBiddings()
        eventContract.setEventBidState(eventId, Event.bidState.buy);
        emit BidBuy(eventId);
    }   

    // Return unsuccessful bidders their corresponding ETH and tokens
    function returnBiddings() public {

    }

    /* Viewing the number of tickets left for an event */
    function viewTicketsLeft(uint256 eventId) public view returns (uint256) {
        return eventContract.getEventTicketsLeft(eventId);
    }

    /* Buyers buying tickets for an event */
    function buyTickets(uint256 eventId, uint8 quantity) public payable isBuyer() {
        require(eventContract.getEventBidState(eventId) == Event.bidState.buy, "Event not open for buying");
        require(quantity > 0, "Quantity of tickets must be at least 1");
        require(quantity <= 4, "You have passed the maximum bulk purchase limit");
        require(eventContract.isEventIdValid(eventId) == true, "Invalid Event");
        require(eventContract.getEventTicketsLeft(eventId) >= quantity, "Not enough tickets");

        uint256 totalPrice = eventContract.getEventTicketPrice(eventId) * quantity;
        require(msg.value >= totalPrice, "Buyer has insufficient ETH to buy tickets");

        // Set remaining tickets after someone buys ticket(s)
        uint256 remainingTickets = eventContract.getEventTicketsLeft(eventId) - quantity;
        eventContract.setEventTicketsLeft(eventId,remainingTickets);

        // Transfer ticket
        uint256 firstTicketId = eventContract.getEventFirstTicketId(eventId);
        uint256 lastTicketId = firstTicketId + eventContract.getEventCapacity(eventId) - 1;

        for (lastTicketId; lastTicketId >= firstTicketId; lastTicketId--) {
            if (ticketContract.getTicketOwner(lastTicketId) == address(this)) {
                ticketContract.transferTicket(lastTicketId, msg.sender);
                quantity--;
                if (quantity == 0) break;
            }
        }

        msg.sender.transfer(msg.value - totalPrice); // transfer remaining back to buyer
        emit TransferToBuyerSuccessful(msg.sender, msg.value - totalPrice);
    }

    function endEvent(uint256 eventId) public isOrganiser() {
        address seller = eventContract.getEventSeller(eventId);
        require(seller == msg.sender, "Only original seller can end event");
        msg.sender.transfer(sellerDepositedValue[seller]);

        // Calculating ticket sales
        uint256 numOfTicketsSold = eventContract.getEventCapacity(eventId) - eventContract.getEventTicketsLeft(eventId);
        uint256 ticketSales = numOfTicketsSold * eventContract.getEventTicketPrice(eventId);

        // Platform keeps 5% commission of ticket sales, rest goes to Seller when event ends
        uint256 sellerProfits = 95 * ticketSales /100;
        msg.sender.transfer(sellerProfits);

        eventContract.endEvent(eventId);
    }

    function calMinimumDeposit(uint256 capacity, uint256 priceOfTicket) public pure returns(uint256){
        // 1USD = 50,000 wei
        return (capacity * priceOfTicket)/2 * 50000;
    }


}