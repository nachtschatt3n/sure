class IdentifyContractsJob < ApplicationJob
  queue_as :default

  # Seeds detected contract candidates for a family. Guarded by a Postgres
  # advisory lock so a burst of sync-complete events (or a manual scan racing a
  # background scan) can't create duplicate detected rows.
  def perform(family_id)
    family = Family.find_by(id: family_id)
    return unless family

    with_advisory_lock(family_id) do
      Contract.identify_for!(family)
    end
  end

  private
    def with_advisory_lock(family_id)
      lock_key = Digest::MD5.hexdigest("identify_contracts:#{family_id}").to_i(16) % (2**31)
      acquired = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ])
      )
      return unless acquired

      begin
        yield
      ensure
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])
        )
      end
    end
end
