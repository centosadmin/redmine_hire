require 'net/http'
require 'uri'

module Hh
  class ApiService
    class RequestError < StandardError
      attr_reader :code, :errors

      def initialize(code:, errors:)
        @code = code
        @errors = errors
        super("Error code: #{code} #{errors.map { |e| "#{e['type']}: #{e['value']}" }.join("\n")}")
      end
    end

    USER_AGENT = 'Redmine/redmine_hire_plugin'
    BASE_URL = 'https://api.hh.ru'

    def initialize
    end

    def execute(vacancies_status)
      vacancies = send("get_#{vacancies_status}_vacancies")
      vacancies.each do |vacancy|
        begin
          ActiveRecord::Base.transaction do
            vacancy_save(vacancy)

            vacancy_responses = get_vacancy_responses(vacancy['id'])

            vacancy_responses.each do |hh_response|
              next if hh_response_present?(hh_response['id'].to_i)
              hh_response_save(hh_response)

              raise "Resume empty" if hh_response['resume'].blank?

              resume = api_get(hh_response['resume']['url'])
              applicant_save(resume)

              cover_letter = get_cover_letter(hh_response['messages_url'])

              IssueBuilder.new(api_data(vacancy, resume, cover_letter, hh_response['id'])).execute
            end
          end
        rescue RequestError => e
          logger.error e.to_s
          logger.error e.backtrace.join("\n")
        end
      end
    rescue RequestError => e
      logger.error e.to_s
      logger.error e.backtrace.join("\n")
    end

    def rollback! # for debug process
      Project.find_by(name: Hh::IssueBuilder::PROJECT_NAME).issues.where.not(resume_id: nil).destroy_all
      HhResponse.destroy_all
      HhApplicant.destroy_all
      HhVacancy.destroy_all
    end

    def send_refusal(issue_id)
      issue = Issue.find(issue_id)
      hh_response = HhResponse.find_by(hh_id: issue&.hh_response_id)
      refusal_url = hh_response&.refusal_url

      return if refusal_url.blank?

      if sidekiq_present?
        RefusalWorker.perform_async(issue_id, refusal_url)
      else
        RefusalWorker.new.perform(issue_id, refusal_url)
      end
    end

    def api_get(url)
      tries ||= 3
      header = {
        content_type: "application/json",
        authorization: "Bearer #{access_token}",
        user_agent: USER_AGENT
      }
      RestClient.get(url, header) do |response, _, _|
        result = JSON.parse(response.body)
        raise RequestError.new(code: response.code, errors: result['errors']) if response.code != 200
        result
      end
    rescue RequestError => e
      if e.code == 403 && e.errors.any? { |error| error['type'] == 'oauth' && error['value'] == 'token_expired' } && !(tries -= 1).zero?
        logger.info('Tokens expired. Trying to reissue...')
        Hh::OAuth.reissue_tokens && retry
      end
      raise
    end

    def api_post(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      header = {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{access_token}",
        "User-Agent" => USER_AGENT
      }
      request = Net::HTTP::Post.new(uri.request_uri, header)
      http.request(request)
    end

    private

    def access_token
      Setting.plugin_redmine_hire['access_token']
    end

    def employer_id
      Setting.plugin_redmine_hire['hh_employer_id']
    end

    def vacancy_save(vacancy)
      vacancy = HhVacancy.find_or_create_by!(hh_id: vacancy['id'])
      vacancy.update!(info: vacancy, info_updated_at: DateTime.current)
    end

    def hh_response_save(hh_response)
      refusal_url = hh_response['actions']
        &.find { |e| e['name'] == 'Отказ' }['templates']
        &.find { |e| e['name'] == "Шаблон быстрого отказа на отклик" }&.[]('url') || nil

      HhResponse.create!(hh_id: hh_response['id'], refusal_url: refusal_url)
    end

    def applicant_save(resume)
      hh_applicant = HhApplicant.find_or_create_by!(hh_id: resume['id'])
      hh_applicant.update!(resume: resume, resume_updated_at: DateTime.current)
    end

    # GET /employers/{employer_id}/vacancies/active // получаем все активные вакансии
    def get_active_vacancies
      api_response = api_get("#{BASE_URL}/employers/#{employer_id}/vacancies/active")
      return api_response['items']
    end

    # GET /employers/{employer_id}/vacancies/archived // получаем все архивные вакансии
    def get_archived_vacancies
      api_response = api_get("#{BASE_URL}/employers/#{employer_id}/vacancies/archived")
      return api_response['items']
    end

    # GET /negotiations/response?vacancy_id={vacancy_id} // получаем отклики из коллекции 'response'
    def get_vacancy_responses(vacancy_id)
      api_response = api_get("#{BASE_URL}/negotiations/response?vacancy_id=#{vacancy_id}")
      return api_response['items']
    end

    def get_cover_letter(messages_url)
      api_response = api_get(messages_url)
      return api_response['items'].first['text']
    end

    def hh_response_present?(id)
      HhResponse.find_by(hh_id: id).present?
    end

    def api_data(vacancy, resume, cover_letter, hh_response_id)
      {
        vacancy_id: vacancy['id'],
        resume_id: resume['id'],
        hh_response_id: hh_response_id,
        vacancy_name: vacancy['name'],
        applicant_city: resume['area']['name'],
        vacancy_city: vacancy['area']['name'],
        vacancy_link: vacancy['alternate_url'],
        applicant_email: resume['contact'].select { |c| c['type']['id'] == 'email' }.first['value'],
        applicant_first_name: resume['first_name'],
        applicant_last_name: resume['last_name'],
        applicant_middle_name: resume['middle_name'],
        applicant_birth_date: resume['birth_date'],
        resume_link: resume['alternate_url'],
        applicant_photo: (resume['photo']['medium'] if resume['photo'].present?),
        salary: (resume['salary']['amount'] if resume['salary'].present?),
        experience: resume['experience'],
        description: resume['skills'],
        cover_letter: cover_letter
      }
    end

    def sidekiq_present?
      sidekiq = Sidekiq rescue nil
      sidekiq.present?
    end

    def logger
      out = Rails.env.production? ? Rails.root.join('log', 'redmine_hire.log') : STDOUT
      @logger ||= Logger.new(out)
    end

    # Пока не используем коллекции откликов, т.к. все наши отклики в колекции 'response'.
    # Если будут отклики в других коллекциях, нужно будет последовательно забирать данные
    # со всех коллекций
    #
    # GET /negotiations?vacancy_id={vacancy_id} // получить все коллекции откликов
    # def get_response_collections(vacancies_ids)
    #   vacancies_ids.each do |vacancy_id|
    #     # do request, get response
    #   end
    # end
  end
end
