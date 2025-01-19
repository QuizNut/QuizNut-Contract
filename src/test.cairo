use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub enum TriviaStatus {
    NotStarted,
    RegistrationOpen,
    InProgress,
    Completed,
}


#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct PrizeDetails {
    entry_fee: u256,
    total_prize_pool: u256,
    current_participants: u32,
    first_place_percentage: u8,
    second_place_percentage: u8,
    third_place_percentage: u8,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct TriviaDetails {
    name: felt252,
    description: felt252,
    registration_deadline: u64,
    start_time: u64,
    min_participants: u32,
    status: TriviaStatus,
    total_rounds: u32,
    current_round: u32,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Question {
    question_text: felt252,
    answer_a: felt252,
    answer_b: felt252,
    answer_c: felt252,
    answer_d: felt252,
    correct_answer: felt252 // Will store 'A', 'B', 'C', or 'D'
}


#[starknet::interface]
trait ITrivia<TContractTrivia> {
    fn check_registration_deadline(self: @TContractTrivia, trivia_id: u32) -> bool;
    fn create_trivia(
        ref self: TContractTrivia,
        name: felt252,
        description: felt252,
        registration_deadline: u64,
        start_time: u64,
        min_participants: u32,
        total_rounds: u32,
        entry_fee: u256,
        first_place_percentage: u8,
        second_place_percentage: u8,
        third_place_percentage: u8,
    );
    fn add_question(
        ref self: TContractTrivia,
        trivia_id: u32,
        question_number: u32,
        question_text: felt252,
        answer_a: felt252,
        answer_b: felt252,
        answer_c: felt252,
        answer_d: felt252,
        correct_answer: felt252,
    );
    fn get_trivia_details(self: @TContractTrivia, trivia_id: u32) -> TriviaDetails;
    fn get_prize_details(self: @TContractTrivia, trivia_id: u32) -> PrizeDetails;
    fn get_trivia_count(self: @TContractTrivia) -> u32;
    fn get_current_time(self: @TContractTrivia) -> u64;
}

#[starknet::contract]
pub mod Trivia {
    use starknet::storage::{StorageMapReadAccess, StorageMapWriteAccess, Map};
    use starknet::{get_block_timestamp, get_caller_address, get_contract_address};
    use super::{TriviaDetails, PrizeDetails, Question, TriviaStatus};

    #[storage]
    struct Storage {
        trivia_details: Map::<u32, TriviaDetails>,
        prize_details: Map::<u32, PrizeDetails>,
        questions: Map<(u32, u32), Question>,
        trivia_counter: u32,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TriviaCreated: TriviaCreated,
        QuestionAdded: QuestionAdded,
        TriviaStarted: TriviaStarted,
    }

    #[derive(Drop, starknet::Event)]
    struct TriviaCreated {
        #[key]
        trivia_id: u32,
        registration_deadline: u64,
        start_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct QuestionAdded {
        #[key]
        trivia_id: u32,
        question_number: u32,
    }

    #[derive(Drop, starknet::Event)]
    struct TriviaStarted {
        #[key]
        trivia_id: u32,
        registration_deadline: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.trivia_counter.write(0_u32); // Just initialize counter to 0
    }

    #[abi(embed_v0)]
    impl TriviaImpl of super::ITrivia<ContractState> {
        fn check_registration_deadline(self: @ContractState, trivia_id: u32) -> bool {
            let trivia_details = self.trivia_details.read(trivia_id);
            let current_time = starknet::get_block_timestamp();
            current_time <= trivia_details.registration_deadline
        }
        fn create_trivia(
            ref self: ContractState,
            name: felt252,
            description: felt252,
            registration_deadline: u64,
            start_time: u64,
            min_participants: u32,
            total_rounds: u32,
            entry_fee: u256,
            first_place_percentage: u8,
            second_place_percentage: u8,
            third_place_percentage: u8,
        ) {
            // Validate time parameters
            let current_time = get_block_timestamp();
            assert(registration_deadline > current_time, 'Invalid registration deadline');
            assert(start_time > registration_deadline, 'Start time must be after reg');

            // Validate prize percentages
            assert(
                first_place_percentage + second_place_percentage + third_place_percentage == 60_u8,
                'Invalid prize distribution',
            );

            // Increment counter first to get new trivia_id
            let trivia_id = self.trivia_counter.read() + 1_u32;
            // Update counter with new ID
            self.trivia_counter.write(trivia_id); // Changed from trivia_id to trivia_counter

            // Create trivia details
            let trivia_details = TriviaDetails {
                name,
                description,
                registration_deadline,
                start_time,
                min_participants,
                status: TriviaStatus::RegistrationOpen,
                total_rounds,
                current_round: 0_u32,
            };

            // Create prize details
            let prize_details = PrizeDetails {
                entry_fee,
                total_prize_pool: 0_u256, // Starts at 0
                current_participants: 0_u32,
                first_place_percentage,
                second_place_percentage,
                third_place_percentage,
            };

            // Store the details
            self.trivia_details.write(trivia_id, trivia_details);
            self.prize_details.write(trivia_id, prize_details);

            // Emit event
            self
                .emit(
                    Event::TriviaCreated(
                        TriviaCreated { trivia_id, registration_deadline, start_time },
                    ),
                );
        }

        fn add_question(
            ref self: ContractState,
            trivia_id: u32,
            question_number: u32,
            question_text: felt252,
            answer_a: felt252,
            answer_b: felt252,
            answer_c: felt252,
            answer_d: felt252,
            correct_answer: felt252,
        ) {
            // Validate trivia exists and is not started
            let mut trivia_details = self.trivia_details.read(trivia_id);
            assert(trivia_details.status != TriviaStatus::InProgress, 'Trivia already started');
            assert(question_number <= trivia_details.total_rounds, 'Invalid question number');

            // Create and store question
            let question = Question {
                question_text, answer_a, answer_b, answer_c, answer_d, correct_answer,
            };
            self.questions.write((trivia_id, question_number), question);

            // Emit event
            self.emit(Event::QuestionAdded(QuestionAdded { trivia_id, question_number }));
        }

        fn get_trivia_details(self: @ContractState, trivia_id: u32) -> TriviaDetails {
            self.trivia_details.read(trivia_id)
        }

        fn get_prize_details(self: @ContractState, trivia_id: u32) -> PrizeDetails {
            self.prize_details.read(trivia_id)
        }

        fn get_trivia_count(self: @ContractState) -> u32 {
            self.trivia_counter.read()
        }

        fn get_current_time(self: @ContractState) -> u64 {
            get_block_timestamp()
        }
    }
}
