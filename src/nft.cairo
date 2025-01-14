//Draft NFT contract not yet integrated with the trivia contract

// SPDX-License-Identifier: MIT
#[starknet::contract]
mod TriviaRewardNFT {
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use openzeppelin::introspection::src5::SRC5Component;
    use starknet::ContractAddress;

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // External
    #[abi(embed_v0)]
    impl ERC721Impl = ERC721Component::ERC721Impl<ContractState>;
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    // Internal
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        // Additional storage for trivia-specific data
        token_metadata: LegacyMap<u256, felt252>, // token_id -> metadata URI
        trivia_id_to_token: LegacyMap<
            u32, (u256, u256, u256)
        >, // trivia_id -> (1st, 2nd, 3rd place tokens)
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        TriviaRewardMinted: TriviaRewardMinted,
    }

    #[derive(Drop, starknet::Event)]
    struct TriviaRewardMinted {
        trivia_id: u32,
        token_id: u256,
        place: u8,
        recipient: ContractAddress
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.erc721.initializer('TriviaRewardNFT', 'TRNFT');
        self.ownable.initializer(owner);
    }

    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn mint_trivia_rewards(
            ref self: ContractState,
            trivia_id: u32,
            first_place: ContractAddress,
            second_place: ContractAddress,
            third_place: ContractAddress
        ) {
            // Only owner can mint rewards
            self.ownable.assert_only_owner();

            // Generate unique token IDs for this trivia
            let base_token_id = trivia_id.into() * 1000;
            let first_token = base_token_id + 1_u256;
            let second_token = base_token_id + 2_u256;
            let third_token = base_token_id + 3_u256;

            // Mint NFTs for each winner
            self._mint_reward(first_token, first_place, trivia_id, 1_u8);
            self._mint_reward(second_token, second_place, trivia_id, 2_u8);
            self._mint_reward(third_token, third_place, trivia_id, 3_u8);

            // Store trivia-token mapping
            self.trivia_id_to_token.write(trivia_id, (first_token, second_token, third_token));
        }

        #[external(v0)]
        fn set_token_metadata(ref self: ContractState, token_id: u256, metadata: felt252) {
            self.ownable.assert_only_owner();
            self.token_metadata.write(token_id, metadata);
        }

        #[external(v0)]
        fn get_trivia_tokens(self: @ContractState, trivia_id: u32) -> (u256, u256, u256) {
            self.trivia_id_to_token.read(trivia_id)
        }

        #[external(v0)]
        fn get_token_metadata(self: @ContractState, token_id: u256) -> felt252 {
            self.token_metadata.read(token_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _mint_reward(
            ref self: ContractState,
            token_id: u256,
            recipient: ContractAddress,
            trivia_id: u32,
            place: u8
        ) {
            self.erc721._mint(recipient, token_id);

            // Emit event
            self
                .emit(
                    TriviaRewardMinted {
                        trivia_id: trivia_id, token_id: token_id, place: place, recipient: recipient
                    }
                );
        }
    }
}
