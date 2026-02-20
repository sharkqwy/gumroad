# frozen_string_literal: true

class CheckPaymentAddressWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    if should_flag_for_fraud?(user)
      user.flag_for_fraud!(author_name: "CheckPaymentAddress") if user.can_flag_for_fraud?
    elsif should_probate_for_tos?(user)
      suspended_account = find_tos_suspended_account(user)
      user.put_on_probation!(
        author_name: "CheckPaymentAddress",
        content: "Probated automatically because of same payout address as User##{suspended_account.id} (suspended for TOS violation)"
      ) if user.can_put_on_probation?
    end
  end

  private
    def should_flag_for_fraud?(user)
      payment_address_matches_fraud_suspended_account?(user) ||
        stripe_fingerprint_matches_fraud_suspended_account?(user) ||
        payment_address_blocked?(user)
    end

    def should_probate_for_tos?(user)
      payment_address_matches_tos_suspended_account?(user) ||
        stripe_fingerprint_matches_tos_suspended_account?(user)
    end

    def find_tos_suspended_account(user)
      if user.payment_address.present?
        account = User.where(
          payment_address: user.payment_address,
          user_risk_state: "suspended_for_tos_violation"
        ).where.not(id: user.id).first
        return account if account
      end

      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      if fingerprints.any?
        BankAccount
          .joins(:user)
          .where(stripe_fingerprint: fingerprints)
          .where.not(user_id: user.id)
          .where(users: { user_risk_state: "suspended_for_tos_violation" })
          .first&.user
      end
    end

    def payment_address_matches_fraud_suspended_account?(user)
      return false if user.payment_address.blank?

      User.where(
        payment_address: user.payment_address,
        user_risk_state: "suspended_for_fraud"
      ).where.not(id: user.id).exists?
    end

    def payment_address_matches_tos_suspended_account?(user)
      return false if user.payment_address.blank?

      User.where(
        payment_address: user.payment_address,
        user_risk_state: "suspended_for_tos_violation"
      ).where.not(id: user.id).exists?
    end

    def payment_address_blocked?(user)
      return false if user.payment_address.blank?

      BlockedObject.find_active_object(user.payment_address).present?
    end

    def stripe_fingerprint_matches_fraud_suspended_account?(user)
      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return false if fingerprints.empty?

      BankAccount
        .joins(:user)
        .where(stripe_fingerprint: fingerprints)
        .where.not(user_id: user.id)
        .where(users: { user_risk_state: "suspended_for_fraud" })
        .exists? || BlockedObject.find_active_objects(fingerprints).present?
    end

    def stripe_fingerprint_matches_tos_suspended_account?(user)
      fingerprints = user.alive_bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
      return false if fingerprints.empty?

      BankAccount
        .joins(:user)
        .where(stripe_fingerprint: fingerprints)
        .where.not(user_id: user.id)
        .where(users: { user_risk_state: "suspended_for_tos_violation" })
        .exists?
    end
end
