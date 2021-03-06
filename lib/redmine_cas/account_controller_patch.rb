require 'redmine_cas'

module RedmineCAS
  module AccountControllerPatch
    def self.included(base)
      base.send(:include, InstanceMethods)
      base.class_eval do
        alias_method_chain :logout, :cas
      end
    end

    module InstanceMethods
      def logout_with_cas
        # if CAS module is inactive => logout in regular fashion
        if !RedmineCAS.enabled?
          return logout_without_cas
        end

        logout_user
        CASClient::Frameworks::Rails::Filter.logout(self, home_url)
      end

      def cas
        return redirect_to :action => 'login' unless RedmineCAS.enabled?

        if User.current.logged?
          # User already logged in.
          return redirect_to_ref_or_default
        end

        if CASClient::Frameworks::Rails::Filter.filter(self)
          user = User.find_by_login(session[:cas_user])

          # Auto-create user if possible
          if user.nil? && RedmineCAS.autocreate_users?
            return redirect_to :action => 'cas_user_register'
          end

          return cas_user_not_found if user.nil?
          return cas_account_pending unless user.active?

          Rails.logger.info "Successful authentication for '#{user.login}' from #{request.remote_ip} at #{Time.now.utc}"
          user.update_attribute(:last_login_on, Time.now)

          cas_login user

          redirect_to_ref_or_default
        end
      end

      def redirect_to_ref_or_default
        default_url = url_for(params.merge(:ticket => nil))
        if params.has_key?(:ref)
          # do some basic validation on ref, to prevent a malicious link to redirect
          # to another site.
          new_url = params[:ref]
          if /http(s)?:\/\/|@/ =~ new_url
            # evil referrer!
            redirect_to default_url
          else
            redirect_to request.base_url + params[:ref]
          end
        else
          redirect_to default_url
        end
      end

      def cas_user_register
        # if username is in database throw error
        if User.current.logged?
          return redirect_to :action => "page", :controller => "my"
        end

        # check that we have an active CAS Session
        if CASClient::Frameworks::Rails::Filter.filter(self)
          @user = User.find_by_login(session[:cas_user])
          if !@user.nil?
            return cas_account_pending unless @user.active?
            cas_login @user

            return redirect_to :action => "page", :controller => "my"
          end

          # check whether we have form data
          if !request.post?
            # create user object
            @user = User.new(:language => Setting.default_language, :admin => false)
            @user.login = session[:cas_user]
            # pre-fill with information from CAS Ticket
            @user.assign_attributes(RedmineCAS.user_extra_attributes_from_session(session))
          else
            # process post params
            user_params = params[:user] || {}
            pref_params = params[:pref] || {}

            @user = User.new
            @user.safe_attributes = user_params
            @user.pref.safe_attributes = pref_params
            # we always set the login to the username of the cas session
            @user.login = session[:cas_user]
            # we do not allow admin creation
            @user.admin = false
            @user.register
            # active user
            @user.activate
            if @user.save
              # perform login
              cas_login @user

              flash[:notice] = l(:notice_account_activated)
              return redirect_to my_account_path
            end # end of save
          end # end of check post

          # at this state always return the form
          return render "redmine_cas/cas_user_register"
        end # end of filter
      end

      def cas_login user
        if RedmineCAS.single_sign_out_enabled?
          # logged_user= would start a new session and break single sign-out
          User.current = user
          start_user_session(user)
        else
          self.logged_user = user
        end
      end

      def cas_account_pending
        render_403 :message => l(:notice_account_pending)
      end

      def cas_user_not_created(user)
        logger.error "Could not auto-create user: #{user.errors.full_messages.to_sentence}"
        render_403 :message => l(:redmine_cas_user_not_created, :user => session[:cas_user])
      end

      def cas_failure
        render_403 :message => l(:redmine_cas_failure)
      end

    end
  end
end
