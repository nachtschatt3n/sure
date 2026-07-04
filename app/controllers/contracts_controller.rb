class ContractsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_contract, only: %i[edit update destroy]

  def index
    @overview = Current.family.contracts_overview
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("contracts.index.title"), nil ]
    ]
  end

  def new
    @contract = Current.family.contracts.new(
      currency: Current.family.primary_currency_code,
      frequency: :monthly
    )
  end

  def create
    @contract = Current.family.contracts.new(contract_params)

    if @contract.save
      redirect_to contracts_path, notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @contract.update(contract_params)
      redirect_to contracts_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @contract.destroy!
    redirect_to contracts_path, notice: t(".success")
  end

  def scan
    created = Contract.identify_for!(Current.family)
    redirect_to contracts_path, notice: t(".success", count: created)
  end

  private
    def set_contract
      @contract = Current.family.contracts.find(params[:id])
    end

    def contract_params
      params.require(:contract).permit(
        :name, :merchant_id, :category_id, :account_id, :frequency,
        :custom_interval_months, :expected_amount, :currency, :expected_day,
        :next_due_date, :status, :provider, :cancellation_notice_days, :notes
      )
    end
end
