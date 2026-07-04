class Contracts::ClusterComponent < ApplicationComponent
  def initialize(cluster:)
    @cluster = cluster
  end

  attr_reader :cluster

  def frequency
    cluster[:frequency]
  end

  def frequency_label
    I18n.t("contracts.frequencies.#{frequency}")
  end

  def count
    cluster[:count]
  end

  def total_amount
    cluster[:total_amount]
  end

  def monthly_normalized
    cluster[:monthly_normalized]
  end

  def contracts
    cluster[:contracts]
  end
end
