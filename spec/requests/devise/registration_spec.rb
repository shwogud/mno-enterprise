require 'rails_helper'

module MnoEnterprise
  RSpec.describe "Remote Registration", type: :request do
    
    let(:confirmation_token) { 'wky763pGjtzWR7dP44PD' }
    let(:user) { build(:user, :unconfirmed, confirmation_token: confirmation_token) }
    let(:email_uniq_resp) { [] }
    let(:signup_attrs) { { name: "John", surname: "Doe", email: 'john@doecorp.com', password: 'securepassword' } }
    
    # Stub user calls
    before { api_stub_for(post: '/users', response: from_api(user)) }
    before { api_stub_for(get: "/users/#{user.id}", response: from_api(user)) }
    before { api_stub_for(put: "/users/#{user.id}", response: from_api(user)) }
    
    # Stub call checking if another user already has the confirmation token provided
    # by devise
    # before { allow(OpenSSL::HMAC).to receive(:hexdigest).and_return(confirmation_token) }
    before { api_stub_for(
      get:'/users',
      params: { filter: { confirmation_token: '**' }, limit: 1 },
      response: from_api([])
    )}
    
    # Stub user email uniqueness check
    # TODO: The email uniqueness validation (using RemoteUniquenessValidator) does not seem
    # to be called....when user is saved. This is extremely weird as it works in real life.
    before { api_stub_for( 
      get: '/users',
      params: { filter: { email: '**' }, limit: 1 },
      response: -> {
        puts "---------------- email validation called -----------------"
        puts "---------- response will be #{email_uniq_resp}"
        from_api(email_uniq_resp)
      } 
    )}
    
    # Stub org_invites retrieval
    before { api_stub_for(get: '/org_invites', response: from_api([])) }
    
    
    describe 'signup' do
      subject { post '/mnoe/auth/users', user: signup_attrs }
      
      describe 'success' do
        before { subject }
        
        # Obscure failure happens when running all specs
        # NoMethodError:
        #        undefined method `clear' for nil:NilClass
        it 'signs the user up' do  
          expect(controller).to be_user_signed_in
          curr_user = controller.current_user
          expect(curr_user.id).to eq(user.id)
          expect(curr_user.name).to eq(user.name)
          expect(curr_user.surname).to eq(user.surname)
        end
      end
      
      describe 'failure' do
        let(:email_uniq_resp) { [from_api(user)] }
        before { subject }
        
        it 'does not log the user in' do
          #user.email = "bla@tamere.com"
          #user.save
          expect(controller).to_not be_user_signed_in
          expect(controller.current_user).to be_nil
        end
      end
    end
  end
end
