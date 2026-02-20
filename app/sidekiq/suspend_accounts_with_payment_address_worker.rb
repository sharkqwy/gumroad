# frozen_string_literal: true

class SuspendAccountsWithPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id, suspension_type = "suspended_for_fraud")
    suspended_user = User.find(user_id)

    suspend_users_with_same_payment_address(suspended_user, suspension_type)
    suspend_users_with_same_stripe_fingerprint(suspended_user, suspension_type)
  end

  private
    def suspend_users_with_same_payment_address(suspended_user, suspension_type)
      return if suspended_user.payment_address.blank?

      User.not_suspended
        .where(payment_address: suspended_user.payment_address)
        .where.not(id: suspended_user.id)
        .find_each do |user|
          handle_related_user(user, suspended_user, "payment address", suspended_user.payment_address, suspension_type)
        end
    end

    def suspend_users_with_same_stripe_fingerprint(suspended_user, suspension_type)
      fingerprints = suspended_user.bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return if fingerprints.empty?

      user_ids_with_same_fingerprint = BankAccount.alive
        .where(stripe_fingerprint: fingerprints)
        .where.not(user_id: suspended_user.id)
        .distinct
        .pluck(:user_id)

      User.not_suspended.where(id: user_ids_with_same_fingerprint).find_each do |user|
        matching_fingerprint = (fingerprints & user.alive_bank_accounts.pluck(:stripe_fingerprint)).first
        handle_related_user(user, suspended_user, "bank account fingerprint", matching_fingerprint, suspension_type)
      end
    end

    def handle_related_user(user, suspended_user, identifier_type, identifier_value, suspension_type)
      if suspension_type == "suspended_for_tos_violation"
        probate_user(user, suspended_user, identifier_type, identifier_value)
      else
        flag_and_suspend_user(user, suspended_user, identifier_type, identifier_value)
      end
    end

    def probate_user(user, suspended_user, identifier_type, identifier_value)
      user.put_on_probation(
        author_name: "suspend_sellers_other_accounts",
        content: "Probated automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{identifier_type} #{identifier_value} (from User##{suspended_user.id} suspended for TOS violation)"
      )
    end

    def flag_and_suspend_user(user, suspended_user, identifier_type, identifier_value)
      user.flag_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Flagged for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{identifier_type} #{identifier_value} (from User##{suspended_user.id})"
      )
      user.suspend_for_fraud(
        author_name: "suspend_sellers_other_accounts",
        content: "Suspended for fraud automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of usage of #{identifier_type} #{identifier_value} (from User##{suspended_user.id})",
        skip_transition_callback: :suspend_sellers_other_accounts
      )
    end
end
