//Contract for Escrow functionality:  including holding, releasing, and refunding funds

use starknet::ContractAddress;

#[starknet::interface]
trait IEscrow<TContractState> {
    fn deposit_entry_fee(ref self: TContractState, amount: u256);
    fn start_trivia(ref self: TContractState);
    fn submit_answer(ref self: TContractState, question_id: u32, answer: felt252, timestamp: u64);
    fn distribute_prizes(ref self: TContractState);
    fn refund(ref self: TContractState);
    fn get_participant_balance(self: @TContractState, account: ContractAddress) -> u256;
    fn get_prize_pool(self: @TContractState) -> u256;
    fn get_minimum_participants(self: @TContractState) -> u32;
    fn get_current_participants(self: @TContractState) -> u32;
    fn is_trivia_started(self: @TContractState) -> bool;
    fn is_trivia_completed(self: @TContractState) -> bool;
    fn get_trivia_start_time(self: @TContractState) -> u64;
    fn get_participant_score(self: @TContractState, participant: ContractAddress) -> (u32, u64);
    fn get_winners(self: @TContractState) -> (ContractAddress, ContractAddress, ContractAddress);
    fn get_prize_distribution(self: @TContractState) -> (u256, u256, u256);
}

#[starknet::contract]
mod Escrow {
    use core::starknet::storage::{StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use super::IEscrow;

    #[storage]
    struct Storage {
        participant_balances: Map<ContractAddress, u256>,
        trivia_contract: ContractAddress,
        erc20_address: ContractAddress,
        current_trivia_id: u32,
        minimum_participants: u32,
        current_participants: u32,
        entry_fee: u256,
        prize_pool: u256,
        trivia_started: bool,
        trivia_completed: bool,
        trivia_start_time: u64,
        correct_answers: Map<u32, felt252>,
        participant_scores: Map<ContractAddress, (u32, u64)>,
        trivia_participants: Map<u32, Array<ContractAddress>>,
        winners: (ContractAddress, ContractAddress, ContractAddress),
        prize_distribution: (u256, u256, u256)
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EntryFeeDeposited: EntryFeeDeposited,
        RewardDistributed: RewardDistributed,
        WinnersDeclared: WinnersDeclared,
        TriviaStarted: TriviaStarted,
    }

    #[derive(Drop, starknet::Event)]
    struct EntryFeeDeposited {
        participant: ContractAddress,
        amount: u256,
        trivia_id: u32
    }

    #[derive(Drop, starknet::Event)]
    struct RewardDistributed {
        winner: ContractAddress,
        amount: u256,
        position: u8
    }

    #[derive(Drop, starknet::Event)]
    struct WinnersDeclared {
        first_place: ContractAddress,
        second_place: ContractAddress,
        third_place: ContractAddress,
        trivia_id: u32
    }

    #[derive(Drop, starknet::Event)]
    struct TriviaStarted {
        trivia_id: u32,
        start_time: u64,
        participant_count: u32
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        trivia_contract: ContractAddress,
        erc20_address: ContractAddress,
        minimum_participants: u32,
        entry_fee: u256
    ) {
        self.trivia_contract.write(trivia_contract);
        self.erc20_address.write(erc20_address);
        self.minimum_participants.write(minimum_participants);
        self.entry_fee.write(entry_fee);
        self.current_trivia_id.write(1);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_trivia_not_started(self: @ContractState) {
            assert(!self.trivia_started.read(), 'Trivia already started');
        }

        fn assert_trivia_started(self: @ContractState) {
            assert(self.trivia_started.read(), 'Trivia not started');
        }

        fn assert_trivia_completed(self: @ContractState) {
            assert(self.trivia_completed.read(), 'Trivia not completed');
        }

        fn assert_valid_entry_fee(self: @ContractState, amount: u256) {
            assert(amount == self.entry_fee.read(), 'Invalid entry fee amount');
        }
    }

    #[abi(embed_v0)]
    impl EscrowImpl of super::IEscrow<ContractState> {
        fn deposit_entry_fee(ref self: ContractState, amount: u256) {
            let caller = get_caller_address();
            self.assert_trivia_not_started();
            self.assert_valid_entry_fee(amount);
            
            let current_balance = self.participant_balances.read(caller);
            assert(current_balance == 0, 'Already paid entry fee');

            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            token.transfer_from(caller, starknet::get_contract_address(), amount);
            
            self.participant_balances.write(caller, amount);
            self.current_participants.write(self.current_participants.read() + 1);
            self.prize_pool.write(self.prize_pool.read() + amount);

            self.emit(Event::EntryFeeDeposited(EntryFeeDeposited { 
                participant: caller, 
                amount,
                trivia_id: self.current_trivia_id.read() 
            }));
        }

        fn start_trivia(ref self: ContractState) {
            self.assert_trivia_not_started();
            let current_participants = self.current_participants.read();
            assert(current_participants >= self.minimum_participants.read(), 'Not enough participants');
            
            self.trivia_started.write(true);
            let start_time = get_block_timestamp();
            self.trivia_start_time.write(start_time);

            self.emit(Event::TriviaStarted(TriviaStarted {
                trivia_id: self.current_trivia_id.read(),
                start_time,
                participant_count: current_participants
            }));
        }

        fn submit_answer(ref self: ContractState, question_id: u32, answer: felt252, timestamp: u64) {
            self.assert_trivia_started();
            let correct_answer = self.correct_answers.read(question_id);
            assert(answer == correct_answer, 'Incorrect answer');
            
            let caller = get_caller_address();
            let (correct_answers, total_time) = self.participant_scores.read(caller);
            self.participant_scores.write(caller, (correct_answers + 1, total_time + timestamp));
        }

        fn distribute_prizes(ref self: ContractState) {
            self.assert_trivia_completed();
            let (first, second, third) = self.winners.read();
            let (first_prize, second_prize, third_prize) = self.prize_distribution.read();
            
            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            
            if (first_prize > 0) {
                token.transfer(first, first_prize);
                self.emit(Event::RewardDistributed(RewardDistributed { 
                    winner: first, 
                    amount: first_prize,
                    position: 1
                }));
            }
            
            if (second_prize > 0) {
                token.transfer(second, second_prize);
                self.emit(Event::RewardDistributed(RewardDistributed { 
                    winner: second, 
                    amount: second_prize,
                    position: 2
                }));
            }
            
            if (third_prize > 0) {
                token.transfer(third, third_prize);
                self.emit(Event::RewardDistributed(RewardDistributed { 
                    winner: third, 
                    amount: third_prize,
                    position: 3
                }));
            }
        }

        fn refund(ref self: ContractState) {
            self.assert_trivia_not_started();
            let caller = get_caller_address();
            let balance = self.participant_balances.read(caller);
            assert(balance > 0, 'No entry fee paid');
            
            let token = IERC20Dispatcher { contract_address: self.erc20_address.read() };
            token.transfer(caller, balance);
            
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

        fn get_winners(self: @ContractState) -> (ContractAddress, ContractAddress, ContractAddress) {
            self.winners.read()
        }

        fn get_prize_distribution(self: @ContractState) -> (u256, u256, u256) {
            self.prize_distribution.read()
        }
    }
}
