//Contract for Escrow functionality:  including holding, releasing, and refunding funds

#[starknet::interface]
pub trait IEscrow<T> {
    // Core functions
    fn deposit_entry_fee(ref self: T, amount: u256); // For users to pay entry fee
    fn start_trivia(ref self: T); // To begin the trivia when minimum participants met
    fn submit_answer(ref self: T, question_id: u32, answer: felt252, timestamp: u64);
    fn distribute_prizes(ref self: T); // Distribute prizes to winners
    fn refund(ref self: T); // Refund if minimum participants not met

    // Utility functions
    fn get_participant_balance(self: @T, account: ContractAddress) -> u256;
    fn get_prize_pool(self: @T) -> u256;
    fn get_minimum_participants(self: @T) -> u32;
    fn get_current_participants(self: @T) -> u32;
    fn is_trivia_started(self: @T) -> bool;
    fn is_trivia_completed(self: @T) -> bool;
    fn get_trivia_start_time(self: @T) -> u64;
    fn get_participant_score(
        self: @T, participant: ContractAddress
    ) -> (u32, u64); // Returns (correct_answers, total_time)
    fn get_winners(
        self: @T
    ) -> (ContractAddress, ContractAddress, ContractAddress); // Returns (first, second, third)
    fn get_prize_distribution(
        self: @T
    ) -> (u256, u256, u256); // Returns prize amounts for 1st, 2nd, 3rd
}


#[starknet::contract]
pub mod escrow {
    use starknet::{ContractAddress, get_caller_address};
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};

    #[storage]
    struct Storage {
        entry_fee: u256,
        prize_pool: u256,
        participant_balances: LegacyMap<ContractAddress, u256>,
        current_participants: u32,
        minimum_participants: u32,
        trivia_started: bool,
        trivia_completed: bool,
        trivia_start_time: u64,
        erc20_address: ContractAddress,
        correct_answers: LegacyMap<u32, felt252>,
        participant_scores: LegacyMap<ContractAddress, (u32, u64)>,
        trivia_address: ContractAddress,
        trivia_contract: ContractAddress,
        trivia_participants: LegacyMap<u32, Array<ContractAddress>>, // trivia_id -> participants
        current_trivia_id: u32,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        entry_fee: u256,
        min_participants: u32,
        erc20_address: ContractAddress,
        correct_answers: Array<felt252>,
        trivia_contract: ContractAddress
    ) {
        self.entry_fee.write(entry_fee);
        self.minimum_participants.write(min_participants);
        self.erc20_address.write(erc20_address);
        self.current_participants.write(0);
        self.trivia_started.write(false);
        self.trivia_completed.write(false);

        // Store correct answers
        let mut i: u32 = 0;
        loop {
            if i >= correct_answers.len() {
                break;
            }
            self.correct_answers.write(i, *correct_answers.at(i));
            i += 1;
        };

        self.trivia_contract.write(trivia_contract);
        self.current_trivia_id.write(0);
    }

    #[external(v0)]
    impl Escrow of super::IEscrow<ContractState> {
        fn deposit_entry_fee(
            ref self: ContractState, amount: u256, referrer: Option<ContractAddress>
        ) {
            let caller = get_caller_address();
            let trivia_id = self.current_trivia_id.read();
            let trivia = ITriviaDispatcher { contract_address: self.trivia_contract.read() };

            // Check registration deadline
            assert(trivia.check_registration_deadline(trivia_id), 'Registration closed');

            // Ensure amount matches entry fee
            let required_fee = self.entry_fee.read();
            assert(amount == required_fee, 'Incorrect entry fee amount');

            // Ensure participant hasn't already paid
            let current_balance = self.participant_balances.read(caller);
            assert(current_balance == 0, 'Already paid entry fee');

            // Transfer tokens from user to contract
            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            token.transfer_from(caller, starknet::get_contract_address(), amount);

            // Update participant balance and count
            self.participant_balances.write(caller, amount);
            self.current_participants.write(self.current_participants.read() + 1);

            // Process referral if provided
            if let Option::Some(referrer_address) = referrer {
                let reward = trivia.process_referral(trivia_id, referrer_address, amount);
                let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
                token.transfer(referrer_address, reward);
            }

            // Update progressive prize pool
            let new_prize_pool = trivia
                .calculate_prize_pool(
                    trivia_id, self.prize_pool.read(), self.current_participants.read()
                );
            self.prize_pool.write(new_prize_pool);

            // Add participant to the current trivia's participant list
            let mut participants = self.trivia_participants.read(trivia_id);
            participants.append(caller);
            self.trivia_participants.write(trivia_id, participants);

            // Update prize details with new participant
            let mut prize_details = trivia.get_prize_details(trivia_id);
            prize_details.current_participants += 1;
            prize_details.total_prize_pool += amount;
            self.prize_details.write(trivia_id, prize_details);
        }

        fn start_trivia(ref self: ContractState) {
            let trivia_id = self.current_trivia_id.read();
            let trivia = ITriviaDispatcher { contract_address: self.trivia_contract.read() };

            // Try to start the trivia
            let started = trivia.start_trivia(trivia_id);
            assert(started, 'Not enough participants');
        }

        fn submit_answer(
            ref self: ContractState, question_id: u32, answer: felt252, timestamp: u64
        ) {
            // Ensure trivia has started
            assert(self.trivia_started.read(), 'Trivia not started');

            // Ensure answer is correct
            let correct_answer = self.correct_answers.read(question_id);
            assert(answer == correct_answer, 'Incorrect answer');

            // Update participant score
            let (correct_answers, total_time) = self.participant_scores.read(get_caller_address());
            self
                .participant_scores
                .write(get_caller_address(), (correct_answers + 1, total_time + timestamp));
        }

        fn distribute_prizes(ref self: ContractState) {
            // Ensure trivia is completed
            assert(self.trivia_completed.read(), 'Trivia not completed');

            let trivia_id = self.current_trivia_id.read();
            let participants = self.trivia_participants.read(trivia_id);

            // First determine and store the winners
            let trivia = ITriviaDispatcher { contract_address: self.trivia_contract.read() };
            trivia.determine_winners(trivia_id, participants, self.participant_scores);

            // Then get them for prize distribution
            let (first_place, second_place, third_place) = trivia.get_winners(trivia_id);

            // Get prize distribution from trivia contract
            let trivia = ITriviaDispatcher { contract_address: self.trivia_contract.read() };
            let (first_prize, second_prize, third_prize) = trivia.get_prize_distribution();

            // Transfer prizes to winners
            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            token.transfer(first_place, first_prize);
            token.transfer(second_place, second_prize);
            token.transfer(third_place, third_prize);

            // Increment trivia ID for next game
            self.current_trivia_id.write(trivia_id + 1);
        }

        fn refund(ref self: ContractState) {
            // Ensure trivia hasn't started
            assert(!self.trivia_started.read(), 'Trivia not started');

            // Get caller address
            let caller = get_caller_address();

            // Ensure caller has paid entry fee
            let balance = self.participant_balances.read(caller);
            assert(balance > 0, 'No entry fee paid');

            // Transfer tokens back to caller
            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            token.transfer(caller, balance);

            // Update participant balance and count
            self.participant_balances.write(caller, 0);
            self.current_participants.write(self.current_participants.read() - 1);
        }

        fn get_participant_balance(self: @ContractState, account: ContractAddress) -> u256 {
            self.participant_balances.read(account)
        }

        fn get_prize_pool(self: @ContractState) -> u256 {
            self.prize_pool.read()
        }

        fn get_minimum_participants(self: @ContractState) -> u32 {
            self.minimum_participants.read()
        }

        fn get_current_participants(self: @ContractState) -> u32 {
            self.current_participants.read()
        }

        fn is_trivia_started(self: @ContractState) -> bool {
            self.trivia_started.read()
        }

        fn is_trivia_completed(self: @ContractState) -> bool {
            self.trivia_completed.read()
        }

        fn get_trivia_start_time(self: @ContractState) -> u64 {
            self.trivia_start_time.read()
        }

        fn get_participant_score(self: @ContractState, participant: ContractAddress) -> (u32, u64) {
            self.participant_scores.read(participant)
        }

        fn get_winners(
            self: @ContractState
        ) -> (ContractAddress, ContractAddress, ContractAddress) {
            self.winners.read()
        }

        fn get_prize_distribution(self: @ContractState) -> (u256, u256, u256) {
            self.prize_distribution.read()
        }

        fn get_correct_answers(self: @ContractState, question_id: u32) -> felt252 {
            self.correct_answers.read(question_id)
        }

        fn get_participant_scores(self: @ContractState) -> LegacyMap<ContractAddress, (u32, u64)> {
            self.participant_scores.read()
        }
    }
}
