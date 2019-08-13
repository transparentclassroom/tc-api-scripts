require 'colorize'
require 'csv'
require_relative './lib/transparent_classroom/client'

PREVIOUS_YEAR = '2018-19'
CURRENT_YEAR = '2019-20'

# Dates assume latest possible start and earliest possible finish
# Min session length is meant to filter out unexpectedly short sessions, i.e. a winter or JTerm session
SCHOOL_YEAR_LATEST_START = '09/15'
SCHOOL_YEAR_EARLIEST_STOP = '05/01'
MIN_SESSION_LENGTH_DAYS = 60

def load_children(tc, school, session)
  children = tc.get 'children.json', params: { session_id: session['id'] }
  children.each { |c| c['school'] = school['name'] }
  children
end

def fingerprint(child)
  "#{child['first_name']} #{child['last_name']}, #{child['birth_date']}"
end

def age_on(child, date)
  return nil if child['birth_date'].blank?

  birth_date = Date.parse(child['birth_date'])
  months = date.month + date.year * 12 - (birth_date.year * 12 + birth_date.month)
  date.day >= birth_date.day ? months : months - 1
end

def format_age(months)
  str = "#{months / 12}y"
  str << " #{months % 12}m" unless months % 12 == 0
  str
end

def to_age(years:, months: 0)
  years * 12 + months
end

def too_old?(classroom, age)
  case classroom['level']
    when '0-1.5'
      age > to_age(years: 1, months: 6)
    when '1.5-3', '0-3'
      age > to_age(years: 3)
    when '3-6'
      age > to_age(years: 6)
    when '6-9'
      age > to_age(years: 9)
    when '6-12'
      age > to_age(years: 12)
    when '9-12'
      age > to_age(years: 12)
    when '12-15'
      age > to_age(years: 15)
    else
      puts "don't know how to handle level #{classroom['level']}".red
      false
  end
end

def name(child)
  "#{child['first_name']} #{child['last_name']}"
end

dir = File.expand_path(File.dirname(__FILE__))

# tc = TransparentClassroom::Client.new base_url: 'http://localhost:3000/api/v1'
tc = TransparentClassroom::Client.new
tc.masquerade_id = 50612 # cam

schools = tc.get 'schools.json'
schools.reject! do |school|
  school['type'] == 'Network' or school['name'] == 'Cloud Flower'
end

# schools = schools[0..2]
# schools.reject! {|s| s['name'] != 'Wisteria Montessori'}
current_children = {}
stats = {}

puts '=' * 100
puts "Loading school years".bold
puts '=' * 100
schools.each do |school|
  puts school['name'].bold

  school['current_year'] = {'sessions'=>[], 'start_date'=>nil, 'stop_date'=>nil}
  school['previous_year'] = {'sessions'=>[], 'start_date'=>nil, 'stop_date'=>nil}

  current_year_start = Date.parse("#{CURRENT_YEAR.split('-')[0]}/#{SCHOOL_YEAR_LATEST_START}")
  current_year_stop  = Date.parse("#{CURRENT_YEAR.split('-')[1]}/#{SCHOOL_YEAR_EARLIEST_STOP}")
  previous_year_start = Date.parse("#{PREVIOUS_YEAR.split('-')[0]}/#{SCHOOL_YEAR_LATEST_START}")
  previous_year_stop  = Date.parse("#{PREVIOUS_YEAR.split('-')[1]}/#{SCHOOL_YEAR_EARLIEST_STOP}")

  tc.school_id = school['id']
  sessions = tc.find_sessions

  # It's possible the school year is broken across multiple sessions
  # Build a list of all sessions for the current and previous school years, also track the unofficial start/end dates
  sessions.each do |s|
    session_start_date = Date.parse(s['start_date'])
    session_stop_date = Date.parse(s['stop_date'])

    # Helper for appending school_year with sessions and earliest start and latest stop dates
    append_current_session_to_school_year = lambda do |school_year|
      school_year['sessions'] << s

      if school_year['start_date'].nil? or Date.parse(school_year['start_date']) < session_start_date
        school_year['start_date'] = s['start_date']
      end

      if school_year['stop_date'].nil? or Date.parse(school_year['stop_date']) > session_stop_date
        school_year['stop_date'] = s['stop_date']
      end
    end

    if session_start_date <= current_year_stop and
       session_stop_date >= current_year_start and
       session_stop_date - session_start_date >= MIN_SESSION_LENGTH_DAYS

      puts "#{CURRENT_YEAR} - '#{s['name']}' (start: #{s['start_date']} - stop: #{s['stop_date']})"
      append_current_session_to_school_year.call(school['current_year'])

    elsif session_start_date <= previous_year_stop and
          session_stop_date >= previous_year_start and
          session_stop_date - session_start_date >= MIN_SESSION_LENGTH_DAYS

      puts "#{PREVIOUS_YEAR} - '#{s['name']}' (start: #{s['start_date']} - stop: #{s['stop_date']})"
      append_current_session_to_school_year.call(school['previous_year'])

    else
      puts "IGNORED - '#{s['name']}' (start: #{s['start_date']} - stop: #{s['stop_date']})"
    end
  end

  puts
end

CSV.open("#{dir}/children_#{CURRENT_YEAR}.csv", 'wb') do |csv|
  csv << [
    'School',
    'First',
    'Last',
    'Birthdate',
  ]
  puts '=' * 100
  puts "Loading Children for #{CURRENT_YEAR}".bold
  puts '=' * 100
  schools.each do |school|
    next if (current_year = school['current_year'])['sessions'].empty?
    tc.school_id = school['id']

    puts school['name'].bold

    current_year['sessions'].each do |session|
      load_children(tc, school, session).each do |child|
        csv << [
          school['name'],
          child['first_name'],
          child['last_name'],
          child['birth_date'],
        ]
        id = fingerprint(child)
        if current_children.has_key?(id)
          puts "Child #{id} is in multiple places in #{CURRENT_YEAR}".red
        else
          current_children[id] = child
        end
      end
    end
  end
end

CSV.open("#{dir}/children_#{PREVIOUS_YEAR}.csv", 'wb') do |csv|
  csv << [
    'School',
    'First',
    'Last',
    'Birthdate',
    'Ethnicity',
    'Household Income',
    'Dominant Language',
    'Classroom',
    'Level',
    'Age',
    'Age in Months',
    "Start of #{CURRENT_YEAR}",
    "Enrolled in #{CURRENT_YEAR}",
    "Aging out of level",
    'Notes',
  ]

  puts
  puts '=' * 100
  puts "Seeing which children from #{PREVIOUS_YEAR} are continuing".bold
  puts '=' * 100
  schools.each do |school|
    stats[school] = school_stats = {
      graduating: [],
      continuing: [],
      dropping: [],
    }
    next if (current_year = school['current_year'])['sessions'].empty? || (previous_year = school['previous_year'])['sessions'].empty?
    tc.school_id = school['id']

    classrooms_by_id = tc.get('classrooms.json').index_by { |c| c['id'] }

    puts school['name'].bold

    date = Date.parse(current_year['start_date'])

    previous_year['sessions'].each do |session|
      load_children(tc, school, session).each do |child|
        notes = []
        classrooms = child['classroom_ids'].map { |id| classrooms_by_id[id] }

        if classrooms.count != 1
          notes << "in multiple classrooms: #{classrooms}"
          puts "#{name child} is in multiple classrooms: #{classrooms}".red
        end
        classroom = classrooms.first

        csv << [
          school['name'],
          child['first_name'],
          child['last_name'],
          child['birth_date'],
          child['ethnicity']&.join(", "),
          child['household_income'],
          child['dominant_language'],
          classroom ? classroom['name'] : nil,
          classroom ? classroom['level'] : nil,
          format_age(age_on(child, date)),
          age_on(child, date),
          date,
          current_children.has_key?(fingerprint(child)) ? 'Y' : 'N',
          too_old?(classroom, age_on(child, date)) ? 'Y' : 'N',
          notes.join("\n"),
        ]

        if too_old?(classroom, age_on(child, date))
          school_stats[:graduating] << child
        elsif current_children.has_key?(fingerprint(child))
          school_stats[:continuing] << child
        else
          school_stats[:dropping] << child
        end
      end
    end
  end
end

puts
puts '=' * 100
puts 'Calculating Retention Rates'.bold
puts '=' * 100
CSV.open("#{dir}/school_rates.csv", 'wb') do |csv|
  csv << [
    'School',
    'Graduating',
    'Continuing',
    'Dropping',
    'Retention Rate',
    'Notes',
  ]
  stats.each do |school, school_stats|
    g, c, d = school_stats[:graduating].length, school_stats[:continuing].length, school_stats[:dropping].length
    row = [school['name'], g, c, d]
    notes = []
    notes << "No #{PREVIOUS_YEAR} session" if school['previous_year']['sessions'].empty?
    notes << "No #{CURRENT_YEAR} session" if school['current_year']['sessions'].empty?

    if g + c + d > 0
      rate = c * 100 / (c + d)
      row << "#{rate}%"
      puts "#{school['name']} => #{rate}% #{notes.join(', ')}"
    else
      row << nil
      puts "#{school['name']} not enough data #{notes.join(', ')}"
    end

    row << notes.join("\n")
    csv << row
  end
end