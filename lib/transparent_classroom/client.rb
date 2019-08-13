require 'rest-client'
require 'active_support/all'
require 'colorize'

module TransparentClassroom
  class Client
    def initialize(api_token: ENV['TC_API_TOKEN'],
                   base_url: 'https://www.transparentclassroom.com/api/v1',
                   school_id: nil,
                   masquerade_id: nil)
      raise "Your api token is blank" if api_token.blank?
      @api_token, @base_url, @school_id, @masquerade_id = api_token, base_url, school_id, masquerade_id
      init_client
    end

    def school_id=(id)
      @school_id = id
      init_client
    end

    def masquerade_id=(id)
      @masquerade_id = id
      init_client
    end

    def get(url, params: {})
      as_json @client[url].get(params: params)
    end

    def post(url, params: {}, body:)
      @client[url].post(body, params: params)
    end

    def find_session(name:)
      sessions = get 'sessions.json'
      if (session = sessions.detect { |s| s['name'] == name })
        session
      else
        puts "Couldn't find session named: #{name}".red
        nil
      end
    end

    def find_session_by_dates(start_date:, stop_date:)
      sessions = get 'sessions.json'
      if (session = sessions.detect { |s|
              Date.parse(s['start_date']) <= Date.parse(start_date) and
              Date.parse(s['start_date']).year == Date.parse(start_date).year and
              Date.parse(s['stop_date']) >= Date.parse(stop_date) and
              Date.parse(s['stop_date']).year == Date.parse(stop_date).year})
        session
      else
        nil
      end
    end

    private

    def as_json(response)
      JSON.parse response.body
    end

    def init_client
      headers = { 'X-TransparentClassroomToken' => @api_token }
      headers['X-TransparentClassroomSchoolId'] = @school_id if @school_id.present?
      headers['X-TransparentClassroomMasqueradeId'] = @masquerade_id if @masquerade_id.present?
      @client = RestClient::Resource.new(@base_url, headers: headers)
    end
  end
end