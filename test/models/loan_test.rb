require "test_helper"

class LoanTest < ActiveSupport::TestCase
  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  test "rate_lock_expiring_soon? is true only for fixed-rate loans within the warning window" do
    fixed_soon = Loan.new(rate_type: "fixed", rate_lock_expires_on: 6.months.from_now.to_date)
    fixed_far = Loan.new(rate_type: "fixed", rate_lock_expires_on: 5.years.from_now.to_date)
    fixed_none = Loan.new(rate_type: "fixed", rate_lock_expires_on: nil)
    variable_soon = Loan.new(rate_type: "variable", rate_lock_expires_on: 6.months.from_now.to_date)

    assert fixed_soon.rate_lock_expiring_soon?
    assert_not fixed_far.rate_lock_expiring_soon?
    assert_not fixed_none.rate_lock_expiring_soon?
    assert_not variable_soon.rate_lock_expiring_soon?
  end
end
