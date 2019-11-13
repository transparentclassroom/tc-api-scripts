require 'base64'
require 'colorize'
require 'csv'
require 'json'
require 'yaml'
require_relative './lib/transparent_classroom/client'
require_relative './lib/name_matcher/matcher'

SCHOOL_YEAR = ENV['SCHOOL_YEAR']

# Dates assume latest possible start and earliest possible finish
# Min session length is meant to filter out unexpectedly short sessions, i.e. a winter or JTerm session
SCHOOL_YEAR_LATEST_START = '09/15'
SCHOOL_YEAR_EARLIEST_STOP = '05/01'
MIN_SESSION_LENGTH_DAYS = 60

def date_from_year_and_month_day(year, month_day)
  Date.parse("#{year}/#{month_day}")
end

def load_schools(tc)
  tc.get 'schools.json'
end

def load_classrooms_by_id(tc, school)
  tc.school_id = school['id']

  classrooms = tc.get('classrooms.json', params: {show_inactive: true})

  classrooms.index_by { |c| c['id'] }
end

def load_children(tc, school, session)
  tc.school_id = school['id']

  children = tc.get 'children.json', params: { session_id: session['id'] }
  children.each { |child| child['school'] = school['name'] }

  children
end

# TC's classrooms endpoint doesn't return 'inactive' classrooms, but the child endpoint will return classroom_ids that point to these 'inactive' classrooms
# This means we can't load classroom objects for all the classrooms a child might be linked to
# This function returns a synthetic classroom, it includes an 'ignore' attribute which checks against the classrooms that have been ignored in the config file
def unknown_classroom_object(school_id, classroom_id)
  level = 'unknown'

  {'id'=>classroom_id, 'name'=>"UNKNOWN (#{classroom_id})", 'level'=>level, 'ignore'=>is_classroom_ignored(school_id, classroom_id)}
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

def infant_toddler_classroom?(classroom)
  if classroom.nil?
    return false
  end

  case classroom['level']
  when '0-1.5', '1.5-3', '0-3'
    true
  when '3-6', '6-9', '6-12', '9-12', '12-15'
    false
  else
    puts "infant_toddler_classroom? - don't know how to handle level #{classroom['level']}".red
    false
  end
end

def too_old?(classroom, age)
  if classroom.nil?
    return false
  end

  case classroom['level']
    when '0-1.5'
      age >= to_age(years: 1, months: 6)
    when '1.5-3', '0-3' # Cutoff age for aging out of toddler is 33 months
      age >= to_age(years: 2, months: 9)
    when '3-6' # Entry age for primary is 33 months
      age >= to_age(years: 6)
    when '6-9'
      age >= to_age(years: 9)
    when '6-12'
      age >= to_age(years: 12)
    when '9-12'
      age >= to_age(years: 12)
    when '12-15'
      age >= to_age(years: 15)
    else
      puts "too_old? - don't know how to handle level #{classroom['level']}".red
      false
  end
end

def name(child)
  "#{child['first_name']} #{child['last_name']}"
end

def new_school_year
  school_year_template = {'children'=>{}, 'sessions'=>[], 'classrooms'=>[], 'start_date'=>nil, 'stop_date'=>nil}
  Marshal.load(Marshal.dump(school_year_template))
end

def get_child_recognized_classrooms(child)
  child['classroom_ids'].map do |id|
    child['school']['classrooms_by_id'][id] || unknown_classroom_object(child['school']['id'], id)
  end.compact
end

def get_child_active_classrooms(child)
  get_child_recognized_classrooms(child)
end

def is_child_in_infant_toddler_classroom?(child)
  classrooms = get_child_active_classrooms(child)

  classrooms.any? do |c|
    infant_toddler_classroom?(c)
  end
end

dir = File.expand_path("output", File.dirname(__FILE__))
FileUtils.mkdir_p(dir) unless File.directory?(dir)

# tc = TransparentClassroom::Client.new base_url: 'http://localhost:3000/api/v1'
tc = TransparentClassroom::Client.new
tc.masquerade_id = ENV['TC_MASQUERADE_ID']

schools = load_schools(tc)

#schools = schools[0..4]
#schools.reject! {|s| s['name'] != 'Acorn Montessori'}
stats = {}

puts '=' * 100
puts "Loading schools".bold
puts '=' * 100
schools.each do |school|
  puts
  puts "Loading #{school['name'].bold}"
  puts '=' * 100

  tc.school_id = school['id']

  # Helper for loading school_year sessions and latest start and earliest stop dates
  # school_year formatting expected to match: e.g. '2018-19'
  load_sessions_for_school_year = lambda do |school_year|
    results = new_school_year.slice('sessions', 'start_date', 'stop_date')

    latest_start = date_from_year_and_month_day(school_year.split('-')[0], SCHOOL_YEAR_LATEST_START)
    earliest_stop = date_from_year_and_month_day(school_year.split('-')[1], SCHOOL_YEAR_EARLIEST_STOP)

    sessions = tc.find_sessions_by_school_year(
        latest_start:    latest_start,
        earliest_stop:   earliest_stop,
        min_school_days: MIN_SESSION_LENGTH_DAYS)
    sessions.each {|s| puts "#{school_year} - '#{s['name']}' (start: #{s['start_date']}, stop: #{s['stop_date']})"}

    results['sessions'] = sessions

    sessions.each do |session|
      session_start_date = Date.parse(session['start_date'])
      session_stop_date = Date.parse(session['stop_date'])

      if results['start_date'].nil? or Date.parse(results['start_date']) < session_start_date
        results['start_date'] = session['start_date']
      end

      if results['stop_date'].nil? or Date.parse(results['stop_date']) > session_stop_date
        results['stop_date'] = session['stop_date']
      end
    end

    results
  end

  load_children_for_sessions = lambda do |sessions|
    children = sessions.map do |session|
      load_children(tc, school, session).map do |child|
        child['school'] = school

        child
      end
    end.flatten

    children.uniq { |c| c['id'] }
  end

  puts
  puts "Loading Sessions"
  puts '-' * 100
  school['current_year'] = new_school_year.merge(load_sessions_for_school_year.call(SCHOOL_YEAR))

  puts
  puts "Loading Classrooms"
  puts '-' * 100
  school['classrooms_by_id'] = load_classrooms_by_id(tc, school)
  puts "Loaded #{school['classrooms_by_id'].count} classrooms"
  school['classrooms_by_id'].each do |_, classroom|
    puts "(#{classroom['id']}) #{classroom['name']} - #{classroom['level']}, active: #{classroom['active']}"
  end

  puts
  puts "Loading Children for #{SCHOOL_YEAR}"
  puts '-' * 100
  school['current_year']['children'] = load_children_for_sessions.call(school['current_year']['sessions'])
  puts "Loaded #{school['current_year']['children'].count} children"

  puts
end

CSV.open("#{dir}/all_children_#{SCHOOL_YEAR}.csv", 'wb') do |csv|
  csv << [
    'child_id',
    'child_raw',
    'school_id',
    'school_name',
    'school_raw',
    'child_first_name',
    'child_last_name',
    'child_birthdate',
    'child_ethnicity',
    'child_household_income',
    'child_dominant_language',
    "classrooms_raw",
    "classroom_ids",
    "classroom_names",
    "classroom_levels",
    "classrooms_aging_out_midyear",
    "in_infant_toddler_classroom",
    "start_of_#{SCHOOL_YEAR}",
    "end_of_#{SCHOOL_YEAR}",
    "age_at_start_of_#{SCHOOL_YEAR}",
    "age_in_months_at_start_of_#{SCHOOL_YEAR}",
    'notes',
  ]
  schools.each do |school|
    current_year = school['current_year']

    next if current_year['children'].empty?

    puts school['name'].bold

    start_date = Date.parse(current_year['start_date'])
    stop_date = Date.parse(current_year['stop_date'])

    current_year['children'].each do |child|
      notes = []

      classrooms = get_child_active_classrooms(child)

      csv << [
          child['id'],
          child.to_json(:except => 'school'),
          school['id'],
          school['name'],
          school.to_json(:except => 'current_year'),
          child['first_name'],
          child['last_name'],
          child['birth_date'],
          child['ethnicity']&.join(", "),
          child['household_income'],
          child['dominant_language'],
          classrooms.to_json,
          classrooms ? classrooms.map {|c| c['id'] }.join(',') : nil,
          classrooms ? classrooms.map {|c| c['name'] }.join(',') : nil,
          classrooms ? classrooms.map {|c| c['level'] }.join(',') : nil,
          classrooms ? classrooms.map {|c| too_old?(c, age_on(child, stop_date))}.join(','): nil,
          is_child_in_infant_toddler_classroom?(child),
          start_date,
          stop_date,
          format_age(age_on(child, start_date)),
          age_on(child, start_date),
          notes.join("\n"),
      ]
    end
  end
end
