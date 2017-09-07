module MnoEnterprise
  class Jpi::V1::Admin::OrganizationsController < Jpi::V1::Admin::BaseResourceController

    DEPENDENCIES = [:app_instances, :'app_instances.app', :users, :'users.user_access_requests', :orga_relations, :invoices, :credit_card, :orga_invites, :'orga_invites.user']
    INCLUDED_FIELDS = [:uid, :name, :account_frozen,
                       :soa_enabled, :mails, :logo, :latitude, :longitude,
                       :geo_country_code, :geo_state_code, :geo_city,
                       :geo_tz, :geo_currency, :metadata, :industry, :size,
                       :financial_year_end_month, :credit_card,
                       :financial_metrics, :created_at]

    # GET /mnoe/jpi/v1/admin/organizations
    def index
      if params[:terms]
        # Search mode
        @organizations = []
        JSON.parse(params[:terms]).map { |t| @organizations = @organizations | MnoEnterprise::Organization.where(Hash[*t]) }
        response.headers['X-Total-Count'] = @organizations.count
      else
        # Index mode
        # Explicitly list fields to be retrieved to trigger financial_metrics calculation
        query = MnoEnterprise::Organization
                .apply_query_params(params)
                .select(INCLUDED_FIELDS)
		
		# TODO: Add these filter parameter directly in the where
        query = query.where(sub_tenant_id: params[:sub_tenant_id]) if params[:sub_tenant_id]
        query = query.where(account_manager_id: params[:account_manager_id]) if params[:account_manager_id]

        @organizations = query.to_a
        response.headers['X-Total-Count'] = query.meta.record_count
      end
    end

    # GET /mnoe/jpi/v1/admin/organizations/1
    def show
      @organization = MnoEnterprise::Organization.find_one(params[:id], *DEPENDENCIES)
      @organization_active_apps = @organization.app_instances.select(&:active?)
    end

    # GET /mnoe/jpi/v1/admin/organizations/in_arrears
    def in_arrears
      @arrears = MnoEnterprise::ArrearsSituation.all
    end

    # GET /mnoe/jpi/v1/admin/organizations/count
    def count
      organizations_count = MnoEnterprise::TenantReporting.show.organizations_count
      render json: {count: organizations_count }
    end

    # POST /mnoe/jpi/v1/admin/organizations
    def create
      # Create new organization
      @organization = MnoEnterprise::Organization.create(organization_update_params)
      @organization = @organization.load_required(*DEPENDENCIES)
      # OPTIMIZE: move this into a delayed job?
      update_app_list
      @organization = @organization.load_required(*DEPENDENCIES)
      @organization_active_apps = @organization.app_instances

      render 'show'
    end

    # PATCH /mnoe/jpi/v1/admin/organizations/1
    def update
      # get organization
      @organization = MnoEnterprise::Organization.find_one(params[:id], *DEPENDENCIES)
      update_app_list
      @organization = @organization.load_required(*DEPENDENCIES)
      @organization_active_apps = @organization.app_instances.select(&:active?)

      render 'show'
    end

    # POST /mnoe/jpi/v1/admin/organizations/1/users
    # Invite a user to the organization (and create it if needed)
    # This does not send any emails (emails are manually triggered later)
    def invite_member
      @organization = MnoEnterprise::Organization.find_one(params[:id], :orga_relations)

      # Find or create a new user - We create it in the frontend as MnoHub will send confirmation instructions for newly
      # created users
      user = MnoEnterprise::User.includes(:orga_relations).where(email: user_params[:email]).first || create_unconfirmed_user(user_params)

      # Create the invitation
      invite = MnoEnterprise::OrgaInvite.create(
        organization_id: @organization.id,
        user_email: user.email,
        user_role: params[:user][:role],
        referrer_id: current_user.id,
        status: 'staged' # Will be updated to 'accepted' for unconfirmed users
      )
      invite = invite.load_required(:user)
      @user = user.confirmed? ? invite : user
    end

    protected

    def organization_permitted_update_params
      [:name]
    end

    def organization_update_params
      params.fetch(:organization, {}).permit(*organization_permitted_update_params)
    end

    def user_params
      params.require(:user).permit(:email, :name, :surname, :phone)
    end

    # Create an unconfirmed user and skip the confirmation notification
    # TODO: monkey patch User#confirmation_required? to simplify this? Use refinements?
    def create_unconfirmed_user(user_params)
      user = MnoEnterprise::User.new(user_params)
      user.skip_confirmation_notification!
      user.password = Devise.friendly_token
      user.save!

      # Reset the confirmation field so we can track when the invite is send - #confirmation_sent_at is when the confirmation_token was generated (not sent)
      # Not ideal as we do 2 saves, and the previous save trigger a call to the backend to validate the token uniqueness
      # TODO: See if we can tell Devise to not set the timestamps
      user.attributes = {confirmation_sent_at: nil, confirmation_token: nil}
      user.save!
      user.load_required(:orga_relations)
    end

    # Update App List to match the list passed in params
    def update_app_list
      # Differentiate between a null app_nids params and no app_nids params
      if params[:organization].key?(:app_nids) && (desired_nids = Array(params[:organization][:app_nids]))
        existing_apps = @organization.app_instances.select(&:active?)
        existing_apps.each do |app_instance|
          desired_nids.delete(app_instance.app.nid) || app_instance.terminate
        end
        desired_nids.each do |nid|
          @organization.provision_app_instance(nid)
        end
      end
    end
  end
end
