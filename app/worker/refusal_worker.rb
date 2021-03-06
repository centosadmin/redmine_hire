class RefusalWorker
  include Hh::Worker

  def initialize(api = Hh::ApiService.new)
    @api = api
  end

  def perform(issue_id, refusal_url)
    issue = Issue.find(issue_id)
    hh_response = HhResponse.find_by(hh_id: issue.hh_response_id)

    refusal_template = api.api_get(refusal_url)
    refusal_text = refusal_template.dig('mail', 'text')

    api.api_put("#{Hh::ApiService::BASE_URL}/negotiations/discard_by_employer/#{hh_response.hh_id}", message: refusal_text)
    write_journal(issue) do |issue|
      issue.refusal!
      issue.journals.create!(user_id: issue.author_id, notes: 'Отказ отправлен.')
    end
  rescue Hh::ApiService::RequestError => e
    logger.error e.to_s
    logger.error e.backtrace.join("\n")
    write_journal(issue) do |issue|
      issue.journals.create!(user_id: issue.author_id, notes: 'Отказ не отправлен, произошла ошибка.')
    end
  end

  private

  attr_reader :api

  def logger
    out = Rails.env.production? ? Rails.root.join('log', 'redmine_hire.log') : STDOUT
    @logger ||= Logger.new(out)
  end

  def write_journal(issue, &_)
    tries = 3
    begin
      Issue.transaction do
        yield(issue)
      end
    rescue ActiveRecord::StaleObjectError
      unless (tries -= 1).zero?
        issue.reload
        retry
      end
      raise
    end
  end
end
