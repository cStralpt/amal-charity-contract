// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract AmalCharity {
    // Platform fee percentage (e.g., 2% = 200, 1% = 100)
    uint256 public platformFeePercentage = 200; // 2%
    // Maximum platform fee percentage (e.g., 5% = 500)
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%
    // Platform wallet address to receive fees
    address public platformWallet;
    // Total platform fees collected
    uint256 public totalPlatformFees;
    // Contract owner (set to the deployer)
    address public owner;
    // Reentrancy guard
    bool internal locked;

    // Enum to define sorting order
    enum SortOrder {
        ASC, // Ascending
        DESC // Descending
    }

    // Struct to represent a Charity Program
    struct Charity {
        uint256 id;
        string name;
        string description;
        string[] imageUrls;
        uint256 targetFunds;
        uint256 raisedFunds;
        address creator;
        bool isActive;
    }

    // Struct to represent a Donation
    struct Donation {
        uint256 charityId;
        address donor;
        uint256 amount;
        uint256 timestamp;
    }

    // Struct to represent a Donation with Charity Data
    struct DonationWithCharity {
        uint256 charityId;
        address donor;
        uint256 amount;
        uint256 timestamp;
        Charity charity; // Include the full charity data
    }

    // Mapping to store charities by their ID
    mapping(uint256 => Charity) public charities;
    // Mapping to store donations by charity ID
    mapping(uint256 => Donation[]) public donationsByCharity;
    // Mapping to store donations by donor address
    mapping(address => Donation[]) public donationsByDonor;
    // Mapping to store charities created by a specific user
    mapping(address => uint256[]) public charitiesByCreator;
    // Counter for charity IDs
    uint256 public charityCounter;

    // Events
    event CharityCreated(
        uint256 id,
        string name,
        string description,
        string[] imageUrls,
        uint256 targetFunds,
        address creator
    );
    event DonationMade(
        uint256 charityId,
        address donor,
        uint256 amount,
        uint256 platformFee,
        uint256 timestamp
    );
    event PlatformFeesWithdrawn(
        address platformWallet,
        uint256 amount,
        uint256 timestamp
    );
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event CharityDeactivated(uint256 charityId, uint256 timestamp);

    // Modifier to restrict access to the owner
    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this");
        _;
    }

    // Modifier to restrict access to the platform wallet
    modifier onlyPlatformWallet() {
        require(msg.sender == platformWallet, "Only platform wallet can call this");
        _;
    }

    // Reentrancy guard modifier
    modifier noReentrancy() {
        require(!locked, "Reentrant call detected");
        locked = true;
        _;
        locked = false;
    }

    // Constructor to set the platform wallet address and owner
    constructor(address _platformWallet) {
        require(_platformWallet != address(0), "Platform wallet cannot be the zero address");
        platformWallet = _platformWallet;
        owner = msg.sender; // Set the deployer as the owner
    }

    // Function to transfer ownership to a new address
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // Function to update the platform fee percentage
    function updatePlatformFee(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= MAX_PLATFORM_FEE, "Fee exceeds maximum allowed");
        emit PlatformFeeUpdated(platformFeePercentage, _newFeePercentage);
        platformFeePercentage = _newFeePercentage;
    }

    // Function to create a new charity program
    function createCharity(
        string memory _name,
        string memory _description,
        string[] memory _imageUrls,
        uint256 _targetFunds
    ) external {
        require(_targetFunds > 0, "Target funds must be greater than 0");
        require(_imageUrls.length > 0, "At least one image URL is required");
        charityCounter++;
        charities[charityCounter] = Charity({
            id: charityCounter,
            name: _name,
            description: _description,
            imageUrls: _imageUrls,
            targetFunds: _targetFunds,
            raisedFunds: 0,
            creator: msg.sender,
            isActive: true
        });
        // Add charity to the creator's list
        charitiesByCreator[msg.sender].push(charityCounter);
        emit CharityCreated(
            charityCounter,
            _name,
            _description,
            _imageUrls,
            _targetFunds,
            msg.sender
        );
    }

    // Function to donate to a charity program
    function donateToCharity(uint256 _charityId) external payable noReentrancy {
        Charity storage charity = charities[_charityId];
        require(charity.isActive, "Charity is no longer active");
        require(msg.value > 0, "Donation amount must be greater than 0");
        require(
            charity.raisedFunds + msg.value <= charity.targetFunds,
            "Donation exceeds target funds"
        );

        // Calculate platform fee based on donation amount and charity progress
        uint256 platformFee = calculatePlatformFee(msg.value, charity);
        uint256 donationAmount = msg.value - platformFee;

        // Update raised funds (excluding platform fee)
        charity.raisedFunds += donationAmount;

        // Add donation to the charity's donation list
        donationsByCharity[_charityId].push(
            Donation({
                charityId: _charityId,
                donor: msg.sender,
                amount: donationAmount,
                timestamp: block.timestamp
            })
        );

        // Add donation to the donor's donation list
        donationsByDonor[msg.sender].push(
            Donation({
                charityId: _charityId,
                donor: msg.sender,
                amount: donationAmount,
                timestamp: block.timestamp
            })
        );

        // Add platform fee to the total platform fees
        totalPlatformFees += platformFee;

        // Close charity if target funds are reached
        if (charity.raisedFunds >= charity.targetFunds) {
            charity.isActive = false;
            emit CharityDeactivated(_charityId, block.timestamp);
        }

        emit DonationMade(_charityId, msg.sender, donationAmount, platformFee, block.timestamp);
    }

    // Function to calculate platform fee based on donation amount and charity progress
    function calculatePlatformFee(uint256 _donationAmount, Charity memory _charity) internal view returns (uint256) {
        uint256 baseFee = (_donationAmount * platformFeePercentage) / 10000; // Base fee (e.g., 2%)
        // Reduce fee for large donations (cap at 0.2 ETH for donations > 10 ETH)
        if (_donationAmount > 10 ether) {
            baseFee = (10 ether * platformFeePercentage) / 10000; // Cap fee at 0.2 ETH
        }
        // Reduce fee for charities close to their target
        if (_charity.raisedFunds >= (_charity.targetFunds * 90) / 100) { // 90% of target
            baseFee = baseFee / 2; // Reduce fee by 50%
        }
        return baseFee;
    }

    // Function to withdraw platform fees (only callable by platform wallet)
    function withdrawPlatformFees() external onlyPlatformWallet noReentrancy {
        require(totalPlatformFees > 0, "No platform fees to withdraw");
        uint256 amountToWithdraw = totalPlatformFees;
        totalPlatformFees = 0; // Reset the total platform fees
        // Transfer the fees to the platform wallet
        payable(platformWallet).transfer(amountToWithdraw);
        emit PlatformFeesWithdrawn(platformWallet, amountToWithdraw, block.timestamp);
    }

    // Function to get all charities with pagination and sorting
    function getAllCharities(uint256 _offset, uint256 _limit, SortOrder _sortOrder)
        external
        view
        returns (Charity[] memory)
    {
        require(_limit > 0, "Limit must be greater than 0");
        // If there are no charities, return an empty array
        if (charityCounter == 0) {
            Charity[] memory emptyResult = new Charity[](0);
            return emptyResult;
        }
        // Ensure the offset is within range
        require(_offset < charityCounter, "Offset out of range");
        uint256 totalCharities = charityCounter;
        uint256 end = _offset + _limit;
        // Ensure the end index does not exceed the total number of charities
        if (end > totalCharities) {
            end = totalCharities;
        }
        // Calculate the number of charities to return
        uint256 resultLength = end - _offset;
        Charity[] memory paginatedCharities = new Charity[](resultLength);
        // Populate the result array
        for (uint256 i = 0; i < resultLength; i++) {
            paginatedCharities[i] = charities[_offset + i + 1]; // Charity IDs start from 1
        }
        // Sort the results based on the specified order
        if (_sortOrder == SortOrder.DESC) {
            _reverseArray(paginatedCharities);
        }
        return paginatedCharities;
    }

    // Function to get all donations for a specific charity with sorting
    function getDonationsByCharity(uint256 _charityId, SortOrder _sortOrder)
        external
        view
        returns (Donation[] memory)
    {
        Donation[] memory donations = donationsByCharity[_charityId];
        if (_sortOrder == SortOrder.DESC) {
            _reverseArray(donations);
        }
        return donations;
    }

    // Function to get all donations made by a specific donor (with charity data and sorting)
    function getDonationsByDonor(address _donor, SortOrder _sortOrder)
        external
        view
        returns (DonationWithCharity[] memory)
    {
        Donation[] memory donorDonations = donationsByDonor[_donor];
        uint256 donationCount = donorDonations.length;

        // Create an array to hold the donations with charity data
        DonationWithCharity[] memory donationsWithCharity = new DonationWithCharity[](donationCount);

        // Populate the array with donation and charity data
        for (uint256 i = 0; i < donationCount; i++) {
            Donation memory donation = donorDonations[i];
            Charity memory charity = charities[donation.charityId];

            donationsWithCharity[i] = DonationWithCharity({
                charityId: donation.charityId,
                donor: donation.donor,
                amount: donation.amount,
                timestamp: donation.timestamp,
                charity: charity // Include the full charity data
            });
        }

        // Sort the results based on the specified order
        if (_sortOrder == SortOrder.DESC) {
            _reverseArray(donationsWithCharity);
        }

        return donationsWithCharity;
    }

    // Function to get all charities created by a specific creator with sorting
    function getCharitiesByCreator(address _creator, SortOrder _sortOrder)
        external
        view
        returns (Charity[] memory)
    {
        uint256[] memory charityIds = charitiesByCreator[_creator];
        Charity[] memory creatorCharities = new Charity[](charityIds.length);
        for (uint256 i = 0; i < charityIds.length; i++) {
            creatorCharities[i] = charities[charityIds[i]];
        }
        // Sort the results based on the specified order
        if (_sortOrder == SortOrder.DESC) {
            _reverseArray(creatorCharities);
        }
        return creatorCharities;
    }

    // Function to get the details of a specific charity
    function getCharityDetails(uint256 _charityId)
        external
        view
        returns (
            uint256 id,
            string memory name,
            string memory description,
            string[] memory imageUrls,
            uint256 targetFunds,
            uint256 raisedFunds,
            address creator,
            bool isActive
        )
    {
        Charity memory charity = charities[_charityId];
        return (
            charity.id,
            charity.name,
            charity.description,
            charity.imageUrls,
            charity.targetFunds,
            charity.raisedFunds,
            charity.creator,
            charity.isActive
        );
    }

    // Function to deactivate a charity (only callable by the creator)
    function deactivateCharity(uint256 _charityId) external {
        Charity storage charity = charities[_charityId];
        require(charity.creator == msg.sender, "Only the creator can deactivate the charity");
        require(charity.isActive, "Charity is already inactive");
        charity.isActive = false;
    }

    // Function to reactivate a charity (only callable by the creator)
    function reactivateCharity(uint256 _charityId) external {
        Charity storage charity = charities[_charityId];
        require(charity.creator == msg.sender, "Only the creator can reactivate the charity");
        require(!charity.isActive, "Charity is already active");
        charity.isActive = true;
    }

    // Function to update the platform wallet address (only callable by the owner)
    function updatePlatformWallet(address _newPlatformWallet) external onlyOwner {
        require(_newPlatformWallet != address(0), "New platform wallet cannot be the zero address");
        platformWallet = _newPlatformWallet;
    }

    // Internal function to reverse an array (used for DESC sorting)
    function _reverseArray(Charity[] memory _array) internal pure {
        uint256 length = _array.length;
        for (uint256 i = 0; i < length / 2; i++) {
            Charity memory temp = _array[i];
            _array[i] = _array[length - i - 1];
            _array[length - i - 1] = temp;
        }
    }

    // Internal function to reverse an array (used for DESC sorting)
    function _reverseArray(Donation[] memory _array) internal pure {
        uint256 length = _array.length;
        for (uint256 i = 0; i < length / 2; i++) {
            Donation memory temp = _array[i];
            _array[i] = _array[length - i - 1];
            _array[length - i - 1] = temp;
        }
    }

    // Internal function to reverse an array (used for DESC sorting)
    function _reverseArray(DonationWithCharity[] memory _array) internal pure {
        uint256 length = _array.length;
        for (uint256 i = 0; i < length / 2; i++) {
            DonationWithCharity memory temp = _array[i];
            _array[i] = _array[length - i - 1];
            _array[length - i - 1] = temp;
        }
    }
}