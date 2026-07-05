class Contracts::OverviewComponent < ApplicationComponent
  def initialize(overview:)
    @overview = overview
  end

  attr_reader :overview

  def clusters
    overview[:clusters]
  end

  def total_count
    overview[:total_count]
  end

  def monthly_total
    overview[:monthly_normalized_total]
  end

  def any_contracts?
    total_count.positive?
  end
end
