require 'base64'
require 'colorize'
require 'csv'
require 'yaml'
require_relative './lib/transparent_classroom/client'
require_relative './lib/name_matcher/matcher'

PREVIOUS_YEAR = '2018-19'
CURRENT_YEAR = '2019-20'

# Dates assume latest possible start and earliest possible finish
# Min session length is meant to filter out unexpectedly short sessions, i.e. a winter or JTerm session
SCHOOL_YEAR_LATEST_START = '09/15'
SCHOOL_YEAR_EARLIEST_STOP = '05/01'
MIN_SESSION_LENGTH_DAYS = 60

CONFIG = begin
  YAML.load_file('config.yml')
rescue
  {
    'rejectSchools' => [],
    'ignoreSchools' => [],
    'ignoreClassrooms' => [],
    'ignoreChildren' => [],
    'groupSchools' => [],
  }
end

def date_from_year_and_month_day(year, month_day)
  Date.parse("#{year}/#{month_day}")
end

def is_school_ignored(school_id, school_name=nil)
  isSchoolIgnored = CONFIG['ignoreSchools'].any? do |ignore|
    school_id == ignore['id'] || (school_name != nil && school_name == ignore['name'])
  end

  isSchoolIgnored
end

def is_classroom_ignored(school_id, classroom_id, school_name=nil, classroom_name=nil)
  isClassroomIgnored = CONFIG['ignoreClassrooms'].any? do |ignore|
    if ignore['schoolId'] == school_id || (school_name != nil && ignore['schoolName'] == school_name)
      ignore['classrooms'].any? do |ignoreClassroom|
        ignoreClassroom['id'] == classroom_id || (classroom_name != nil && ignoreClassroom['name'] == classroom_name)
      end
    end
  end

  isClassroomIgnored
end

def is_child_ignored(school_id, classroom_ids, child_id, school_name=nil, classroom_names=nil, child_name)
  is_child_school_ignored = is_school_ignored(school_id, school_name)

  are_all_child_classrooms_ignored = classroom_ids.all? do |classroom_id|
    is_classroom_ignored(school_id, classroom_id, school_name)
  end

  is_child_explicitly_ignored = CONFIG['ignoreChildren'].any? do |ignore|
    if ignore['schoolId'] == school_id or ignore['schoolName'] == school_name
      ignore['children'].any? do |ignoreChildren|
        ignoreChildren['id'] == child_id || ignoreChildren['name'] == child_name
      end
    end
  end

  is_child_school_ignored || are_all_child_classrooms_ignored || is_child_explicitly_ignored
end

def load_schools(tc)
  schools = tc.get 'schools.json'

  schools.reject! do |school|
    CONFIG['rejectSchools'].any? do |ignore|
      school['name'] == ignore['name'] || school['id'] == ignore['id']
    end
  end

  schools.each do |school|
    school['ignore'] = is_school_ignored(school['id'], school['name'])
  end
  schools
end

def load_classrooms_by_id(tc, school)
  tc.school_id = school['id']

  classrooms = tc.get('classrooms.json', params: {show_inactive: true})
  classrooms.each do |c|
    c['ignore'] = is_classroom_ignored(school['id'], c['id'], school['name'], c['name'])
  end

  classrooms.index_by { |c| c['id'] }
end

def load_children(tc, school, session)
  tc.school_id = school['id']

  children = tc.get 'children.json', params: { session_id: session['id'] }
  children.each { |child| child['school'] = school['name'] }

  children.each do |child|
    child['ignore'] = is_child_ignored(
        school_id=school['id'],
        classroom_ids=child['classroom_ids'],
        child_id=child['id'],
        school_name=school['name'],
        classroom_names=nil,
        child_name=name(child))
  end

  children
end

# TC's classrooms endpoint doesn't return 'inactive' classrooms, but the child endpoint will return classroom_ids that point to these 'inactive' classrooms
# This means we can't load classroom objects for all the classrooms a child might be linked to
# This function returns a synthetic classroom, it includes an 'ignore' attribute which checks against the classrooms that have been ignored in the config file
def unknown_classroom_object(school_id, classroom_id)
  level = 'unknown'

  {'id'=>classroom_id, 'name'=>"UNKNOWN (#{classroom_id})", 'level'=>level, 'ignore'=>is_classroom_ignored(school_id, classroom_id)}
end

def fingerprint(child)
  Base64.encode64("#{child['first_name'].strip.downcase} #{child['last_name'].strip.downcase}, #{child['birth_date']}")
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

# Check if child will turn 5 at some point between start of previous school year through start of next school
def is_child_kindergarten_eligible?(child, previous_year_start, current_year_start)
  age_on(child, previous_year_start) < to_age(years: 5, months: 0) && age_on(child, current_year_start) >= to_age(years: 5, months: 0)
end

def age_appropriate_for_school?(school, age)
  classrooms_by_id = school['classrooms_by_id']

  age_appropriate = false

  classrooms_by_id.each do |id, classroom|
    # skip this classroom if it can't be found or if the classroom is in the ignored list
    if classroom == nil || is_classroom_ignored(school['id'], id, school['name'], classroom['name'])
      next
    end

    age_appropriate = age_appropriate?(classroom, age)
    break if age_appropriate
  end

  age_appropriate
end

def age_appropriate?(classroom, age)
  if classroom.nil?
    return true
  end

  case classroom['level']
    when '0-1.5'
      age >= to_age(years: 0, months: 0) && age < to_age(years: 1, months: 6)
    when '1.5-3', '0-3' # Cutoff age for aging out of toddler is 33 months
      age >= to_age(years: 1, months: 6) && age < to_age(years: 2, months: 9)
    when '3-6' # Entry age for primary is 33 months
      age >= to_age(years: 2, months: 9) && age < to_age(years: 6)
    when '6-9'
      age >= to_age(years: 6, months: 0) && age < to_age(years: 9)
    when '6-12'
      age >= to_age(years: 6, months: 0) && age < to_age(years: 12)
    when '9-12'
      age >= to_age(years: 9, months: 0) && age < to_age(years: 12)
    when '12-15'
      age >= to_age(years: 12, months: 0) && age < to_age(years: 15)
    else
      puts "don't know how to handle level #{classroom['level']}".red
      true
  end
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
  classrooms = child['classroom_ids'].map do |id|
    child['school']['classrooms_by_id'][id] || unknown_classroom_object(child['school']['id'], id)
  end.compact

  classrooms.reject {|c| c['ignore']}
end

def get_child_ignored_classrooms(child)
  classrooms = child['classroom_ids'].map do |id|
    child['school']['classrooms_by_id'][id] || unknown_classroom_object(child['school']['id'], id)
  end.compact

  classrooms.select {|c| c['ignore']}
end

def get_child_active_classroom(child)
  classrooms_recognized = get_child_recognized_classrooms(child)

  if classrooms_recognized.count > 1
      # notes << "Child in multiple classrooms, defaulting to first in list: #{classrooms_recognized}"
      puts "#{name child} is in multiple recognized classrooms: #{classrooms_recognized}".red
  end

  classrooms_recognized.first
end

def child_ignored_list(child)
  classrooms_ignored = get_child_ignored_classrooms(child)
  classroom = get_child_active_classroom(child)

  {
    ignoredChild: child['ignore'],
    ignoredClassroom: classroom.nil? && classrooms_ignored.count > 0,
    ignoredSchool: child['school']['ignore'],
  }
end

def is_child_in_infant_toddler_classroom?(child)
  classroom = get_child_active_classroom(child)

  infant_toddler_classroom?(classroom)
end

# def is_child_ignored(child)
#   child_ignored_list(child).values.reduce(false) { |agg, reason| agg || reason }
# end

def reasons_child_ignored_details(child)
  details = []

  ignored_list = child_ignored_list(child)

  if ignored_list[:ignoredClassroom]
    details << "Ignored - child only present in ignored classroom list ('#{get_child_ignored_classrooms(child)}')"
  end

  if ignored_list[:ignoredSchool]
    details << "Ignored - in ignored school list ('#{child['school']['name']}')"
  end

  if ignored_list[:ignoredChild]
    details << "Ignored - in ignored child list"
  end

  details
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
        child['fingerprint'] = fingerprint(child)

        child
      end
    end.flatten

    children.uniq { |c| c['id'] }
  end

  puts
  puts "Loading Sessions"
  puts '-' * 100
  school['previous_year'] = new_school_year.merge(load_sessions_for_school_year.call(PREVIOUS_YEAR))
  school['current_year'] = new_school_year.merge(load_sessions_for_school_year.call(CURRENT_YEAR))

  puts
  puts "Loading Classrooms"
  puts '-' * 100
  school['classrooms_by_id'] = load_classrooms_by_id(tc, school)
  puts "Loaded #{school['classrooms_by_id'].count} classrooms"
  school['classrooms_by_id'].each do |_, classroom|
    puts "(#{classroom['id']}) #{classroom['name']} - #{classroom['level']}, active: #{classroom['active']}"
  end

  puts
  puts "Loading Children for #{PREVIOUS_YEAR}"
  puts '-' * 100
  school['previous_year']['children'] = load_children_for_sessions.call(school['previous_year']['sessions'])
  puts "Loaded #{school['previous_year']['children'].count} children"

  puts
  puts "Loading Children for #{CURRENT_YEAR}"
  puts '-' * 100
  school['current_year']['children'] = load_children_for_sessions.call(school['current_year']['sessions'])
  puts "Loaded #{school['current_year']['children'].count} children"

  puts
end

puts
puts "Organizing Collection of All Children for #{PREVIOUS_YEAR}".bold
puts '=' * 100
previous_years_children = {}
schools.each do |school|
  school['previous_year']['children'].each do |child|
    fid = child['fingerprint']
    if previous_years_children.has_key?(fid)
      puts "Child #{name(child)} (#{child['id']}) is in multiple places in #{PREVIOUS_YEAR}".red
    else
      previous_years_children[fid] = child
    end
  end
end

def does_children_collection_include(children, child)
  # if children.has_key?(child['fingerprint']) && not(is_child_ignored(children[child['fingerprint']]))
  if children.has_key?(child['fingerprint']) && not(children[child['fingerprint']]['ignore'])
    return [true, children[child['fingerprint']]]
  end

  children_with_birthdate = children.values.select { |c| child['birth_date'] == c['birth_date'] && not(c['ignore']) }
  if children_with_birthdate.empty?
    return [false, nil]
  end

  puts "Performing fuzzy match on #{name(child)}"
  nearest = children_with_birthdate.map{ |c| {c => NamesMatcher.distance(name(child), name(c))}}.min_by{|r| r.values}
  match = nearest.values.first <= 0.8
  if match
    puts "Found #{name(nearest.keys.first)} w/ distance #{nearest.values.first}"
    return [true, nearest.keys.first]
  else
    puts "No match, nearest candidate #{name(nearest.keys.first)} w/ distance #{nearest.values.first}"
    return [false, nil]
  end
end

puts
puts "Organizing Collection of All Children for #{CURRENT_YEAR}".bold
puts '=' * 100
current_years_children = {}
schools.each do |school|
  school['current_year']['children'].each do |child|
    fid = child['fingerprint']
    if current_years_children.has_key?(fid)
      puts "Child #{name(child)} (#{child['id']}) is in multiple places in #{CURRENT_YEAR}".red
    else
      current_years_children[fid] = child
    end
  end
end

CSV.open("#{dir}/children_#{CURRENT_YEAR}.csv", 'wb') do |csv|
  csv << [
    'ID',
    'School',
    'First',
    'Last',
    'Birthdate',
    'Ethnicity',
    'Household Income',
    'Dominant Language',
    "Classroom in #{CURRENT_YEAR}",
    "Level in #{CURRENT_YEAR}",
    "In Infant/Toddler Classroom in #{CURRENT_YEAR}",
    "Start of #{CURRENT_YEAR}",
    "End of #{CURRENT_YEAR}",
    "Age at Start of #{CURRENT_YEAR}",
    "Age in Months at Start of #{CURRENT_YEAR}",
    "Enrolled in #{CURRENT_YEAR}",
    "Enrolled in #{PREVIOUS_YEAR}",
    "Enrolled at Different School in #{PREVIOUS_YEAR}",
    "Matched Child ID",
    "Aging out Midyear",
    "Ignored",
    'Notes',
  ]
  schools.each do |school|
    current_year = school['current_year']
    previous_year = school['previous_year']

    next if current_year['children'].empty?

    puts school['name'].bold

    start_date = Date.parse(current_year['start_date'])
    stop_date = Date.parse(current_year['stop_date'])

    current_year['children'].each do |child|
      notes = []

      ignored = child['ignore']
      if ignored
        notes.concat(reasons_child_ignored_details(child))
      end

      classroom = get_child_active_classroom(child)

      is_currently_enrolled_in_network, _ = does_children_collection_include(current_years_children, child)
      was_previously_enrolled_in_network, previous_year_child_match = does_children_collection_include(previous_years_children, child)

      previous_year_child_match_id = nil
      if was_previously_enrolled_in_network
        previous_year_child_match_id = previous_year_child_match['id']
        notes << "Matched with previous year child - id: #{previous_year_child_match_id} name: #{name(previous_year_child_match)}"
      end

      # was_previously_at_current_school = previous_year['children'].any? {|c| c['fingerprint'] == child['fingerprint'] && not(c['ignore'])}
      was_previously_at_current_school = was_previously_enrolled_in_network && child['school']['id'] == previous_year_child_match['school']['id']
      was_previously_at_different_school = was_previously_enrolled_in_network && not(was_previously_at_current_school)

      csv << [
          child['id'],
          school['name'],
          child['first_name'],
          child['last_name'],
          child['birth_date'],
          child['ethnicity']&.join(", "),
          child['household_income'],
          child['dominant_language'],
          classroom ? classroom['name'] : nil,
          classroom ? classroom['level'] : nil,
          is_child_in_infant_toddler_classroom?(child),
          start_date,
          stop_date,
          format_age(age_on(child, start_date)),
          age_on(child, start_date),
          is_currently_enrolled_in_network,
          was_previously_enrolled_in_network,
          was_previously_at_different_school,
          previous_year_child_match_id,
          too_old?(classroom, age_on(child, stop_date)) ? 'Y' : 'N',
          ignored ? 'Y' : 'N',
          notes.join("\n"),
      ]
    end
  end
end

CSV.open("#{dir}/children_#{PREVIOUS_YEAR}.csv", 'wb') do |csv|
  csv << [
    'ID',
    'School',
    'First',
    'Last',
    'Birthdate',
    'Ethnicity',
    'Household Income',
    'Dominant Language',
    "Classroom in #{PREVIOUS_YEAR}",
    "Level in #{PREVIOUS_YEAR}",
    "In Infant/Toddler Classroom in #{PREVIOUS_YEAR}",
    "Start of #{CURRENT_YEAR}",
    "Age at Start of #{CURRENT_YEAR}",
    "Age in Months at Start of #{CURRENT_YEAR}",
    "Enrolled in #{PREVIOUS_YEAR}",
    "Enrolled in #{CURRENT_YEAR}",
    "Enrolled at Different School in #{CURRENT_YEAR}",
    "Matched Child ID",
    "Aging out of Level",
    "Age Appropriate for School in #{CURRENT_YEAR}",
    "Graduated School",
    "Continued School",
    "Continued Network",
    "Dropped School",
    'Kindergarten Eligible Year',
    'Ignored',
    'Notes',
  ]

  puts
  puts '=' * 100
  puts "Seeing which children from #{PREVIOUS_YEAR} are continued".bold
  puts '=' * 100
  schools.each do |school|
    #next if (current_year = school['current_year'])['sessions'].empty? || (previous_year = school['previous_year'])['sessions'].empty?
    current_year = school['current_year']
    previous_year = school['previous_year']

    stats[school['id']] = school_stats = {
      graduated_school: [],
      graduated_school_and_continued_in_network: [],
      continued: [],
      continued_at_school: [],
      continued_in_network: [],
      continued_at_school_kindergarten: [],
      continued_in_network_kindergarten: [],
      continued_at_school_infant_toddler: [],
      continued_in_network_infant_toddler: [],
      continued_at_school_kindergarten_or_infant_toddler: [],
      continued_in_network_kindergarten_or_infant_toddler: [],
      dropped_school: [],
      dropped_school_but_continued_in_network: [],
      dropped_school_kindergarten: [],
      dropped_school_but_continued_in_network_kindergarten: [],
      dropped_school_infant_toddler: [],
      dropped_school_but_continued_in_network_infant_toddler: [],
      dropped_school_kindergarten_or_infant_toddler: [],
      dropped_school_but_continued_in_network_kindergarten_or_infant_toddler: [],
      enrolled_current_year: current_year['children'].reject{ |c| c['ignore'] },
      enrolled_previous_year: previous_year['children'].reject{ |c| c['ignore'] },
    }

    next if previous_year['children'].empty?

    puts school['name'].bold

    start_date = Date.parse(current_year['start_date'])

    previous_year['children'].each do |child|
      notes = []

      ignored = child['ignore']
      if ignored
        notes.concat(reasons_child_ignored_details(child))
      end
      is_child_kindergarten_eligible = is_child_kindergarten_eligible?(child, Date.parse(previous_year['start_date']), Date.parse(current_year['start_date']))
      in_infant_toddler_classroom = is_child_in_infant_toddler_classroom?(child)

      classroom = get_child_active_classroom(child)

      is_currently_enrolled_in_network, current_year_child_match = does_children_collection_include(current_years_children, child)
      was_previously_enrolled_in_network, _ = does_children_collection_include(previous_years_children, child)

      current_year_child_match_id = nil
      if is_currently_enrolled_in_network
        current_year_child_match_id = current_year_child_match['id']
        notes << "Matched with current year child - id: #{current_year_child_match_id} name: #{name(current_year_child_match)}"
      end

      #is_continued_at_current_school = current_year['children'].any? {|c| c['fingerprint'] == child['fingerprint'] && not(c['ignore'])}
      is_continued_at_current_school = is_currently_enrolled_in_network && child['school']['id'] == current_year_child_match['school']['id']
      is_continued_at_different_school = is_currently_enrolled_in_network && not(is_continued_at_current_school)

      graduated_school = !age_appropriate_for_school?(school, age_on(child, start_date)) && !is_continued_at_current_school
      dropped_school = age_appropriate_for_school?(school, age_on(child, start_date)) && !is_continued_at_current_school

      csv << [
        child['id'],
        school['name'],
        child['first_name'],
        child['last_name'],
        child['birth_date'],
        child['ethnicity']&.join(", "),
        child['household_income'],
        child['dominant_language'],
        classroom ? classroom['name'] : nil,
        classroom ? classroom['level'] : nil,
        in_infant_toddler_classroom,
        start_date,
        format_age(age_on(child, start_date)),
        age_on(child, start_date),
        was_previously_enrolled_in_network,
        is_currently_enrolled_in_network,
        is_continued_at_different_school,
        current_year_child_match_id,
        too_old?(classroom, age_on(child, start_date)) ? 'Y' : 'N',
        age_appropriate_for_school?(school, age_on(child, start_date)),
        graduated_school,
        is_continued_at_current_school,
        is_currently_enrolled_in_network,
        dropped_school,
        is_child_kindergarten_eligible,
        ignored ? 'Y' : 'N',
        notes.join("\n"),
      ]

      # Do not compute stats on ignored children
      if ignored
        next
      end

      # too_old?(classroom, age_on(child, start_date)) && !is_continued_at_current_school

      if graduated_school
        school_stats[:graduated_school] << child
      end

      if graduated_school && is_currently_enrolled_in_network
        school_stats[:graduated_school_and_continued_in_network] << child
      end

      if is_continued_at_current_school || is_currently_enrolled_in_network
        school_stats[:continued] << child

        if is_continued_at_current_school
          school_stats[:continued_at_school] << child

          if is_child_kindergarten_eligible
            school_stats[:continued_at_school_kindergarten] << child
          end

          if in_infant_toddler_classroom
            school_stats[:continued_at_school_infant_toddler] << child
          end

          if is_child_kindergarten_eligible || in_infant_toddler_classroom
            school_stats[:continued_at_school_kindergarten_or_infant_toddler] << child
          end
        else
          school_stats[:continued_in_network] << child

          if is_child_kindergarten_eligible
            school_stats[:continued_in_network_kindergarten] << child
          end

          if in_infant_toddler_classroom
            school_stats[:continued_in_network_infant_toddler] << child
          end

          if is_child_kindergarten_eligible || in_infant_toddler_classroom
            school_stats[:continued_in_network_kindergarten_or_infant_toddler] << child
          end
        end
      end

      if dropped_school
        school_stats[:dropped_school] << child

        if is_child_kindergarten_eligible
          school_stats[:dropped_school_kindergarten] << child
        end

        if in_infant_toddler_classroom
          school_stats[:dropped_school_infant_toddler] << child
        end

        if is_child_kindergarten_eligible || in_infant_toddler_classroom
          school_stats[:dropped_school_kindergarten_or_infant_toddler] << child
        end

        if is_currently_enrolled_in_network
          school_stats[:dropped_school_but_continued_in_network] << child

          if is_child_kindergarten_eligible
            school_stats[:dropped_school_but_continued_in_network_kindergarten] << child
          end

          if in_infant_toddler_classroom
            school_stats[:dropped_school_but_continued_in_network_infant_toddler] << child
          end

          if is_child_kindergarten_eligible || in_infant_toddler_classroom
            school_stats[:dropped_school_but_continued_in_network_kindergarten_or_infant_toddler] << child
          end
        end
      end
    end
  end
end

puts
puts '=' * 100
puts 'Calculating School Retention Rates'.bold
puts '=' * 100
CSV.open("#{dir}/school_retention.csv", 'wb') do |csv|
  csv << [
    'School',
    "#{PREVIOUS_YEAR} Total Children",
    "#{CURRENT_YEAR} Total Children",
    'Graduated from School',
    'Graduated from School and Continued in Network',
    'Continued',
    'Continued at School',
    'Continued in Network',
    'Continued at School (Kindergarten Eligible)',
    'Continued in Network (Kindergarten Eligible)',
    'Continued at School (Infant/Toddler Classroom)',
    'Continued in Network (Infant/Toddler Classroom)',
    'Continued at School (Kindergarten & Infant/Toddler Classroom)',
    'Continued in Network (Kindergarten & Infant/Toddler Classroom)',
    'Dropped School',
    'Dropped School but Continued in Network',
    'Dropped School (Kindergarten Eligible)',
    'Dropped School but Continued in Network (Kindergarten Eligible)',
    'Dropped School (Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Infant/Toddler Classroom)',
    'Dropped School (Kindergarten & Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Kindergarten & Infant/Toddler Classroom)',
    'Retention Rate',
    'Retention Rate (Ignoring Kindergarten Eligible)',
    'Retention Rate (Ignoring Infant/Toddler Classroom)',
    'Retention Rate (Ignoring Kindergarten Eligible & Infant/Toddler Classroom)',
    'Notes',
  ]
  stats.each do |school_id, school_stats|
    school = schools.find{ |s| s['id'] == school_id }
    tp, tc = school_stats[:enrolled_previous_year].length, school_stats[:enrolled_current_year].length
    gs, gsc = school_stats[:graduated_school].length, school_stats[:graduated_school_and_continued_in_network].length
    c = school_stats[:continued].length
    cs, cn = school_stats[:continued_at_school].length, school_stats[:continued_in_network].length
    csk, cnk = school_stats[:continued_at_school_kindergarten].length, school_stats[:continued_in_network_kindergarten].length
    csit, cnit = school_stats[:continued_at_school_infant_toddler].length, school_stats[:continued_in_network_infant_toddler].length
    cskit, cnkit = school_stats[:continued_at_school_kindergarten_or_infant_toddler].length, school_stats[:continued_in_network_kindergarten_or_infant_toddler].length
    ds, dscn = school_stats[:dropped_school].length, school_stats[:dropped_school_but_continued_in_network].length
    dsk, dscnk = school_stats[:dropped_school_kindergarten].length, school_stats[:dropped_school_but_continued_in_network_kindergarten].length
    dsit, dscnit = school_stats[:dropped_school_infant_toddler].length, school_stats[:dropped_school_but_continued_in_network_infant_toddler].length
    dskit, dscnkit = school_stats[:dropped_school_kindergarten_or_infant_toddler].length, school_stats[:dropped_school_but_continued_in_network_kindergarten_or_infant_toddler].length
    row = [school['name'], tp, tc, gs, gsc, c, cs, cn, csk, cnk, csit, cnit, cskit, cnkit, ds, dscn, dsk, dscnk, dsit, dscnit, dskit, dscnkit]
    notes = []

    ignored = false
    if school['ignore']
      notes << "Ignored - in ignored school list ('#{school['name']}')"
      ignored = true
    else
      if school['previous_year']['sessions'].empty?
        notes << "No #{PREVIOUS_YEAR} session"
        ignored = true
      end
      if school['current_year']['sessions'].empty?
        notes << "No #{CURRENT_YEAR} session"
        ignored = true
      end
      # Total previous year must be greater than 0
      if tp == 0
        notes << "No children enrolled in previous year (not including ignored children)"
        ignored = true
      end
    end

    if ignored
      row.concat(Array.new(4, nil))
      puts "#{school['name']} not enough session/children data: #{notes.join(', ')}"
    elsif (cs + ds) > 0 # Computing retention rate at school specifically, i.e. not considering when child continues in network
      rate = ((cs * 100.0) / (cs + ds)).round
      row << "#{rate}%"
      puts "#{school['name']} => #{rate}% #{notes.join(', ')}"

      # Kindergarten retention
      if (cs - csk + ds - dsk) > 0
        krate = (((cs - csk) * 100.0) / (cs - csk + ds - dsk)).round
        row << "#{krate}%"
        puts "#{school['name']} Kindergarten Rate => #{krate}%"
      else
        #row << "100%"
        row << nil
      end

      # Infant Toddler retention
      if (cs - csit + ds - dsit) > 0
        itrate = (((cs - csit) * 100.0) / (cs - csit + ds - dsit)).round
        row << "#{itrate}%"
        puts "#{school['name']} Infant/Toddler Rate => #{itrate}%"
      else
        #row << "100%"
        row << nil
      end

      # Kindergarten or Infant Toddler retention
      if (cs - cskit + ds - dskit) > 0
        kitrate = (((cs - cskit) * 100.0) / (cs - cskit + ds - dskit)).round
        row << "#{kitrate}%"
        puts "#{school['name']} Infant/Toddler Rate => #{kitrate}%"
      else
        #row << "100%"
        row << nil
      end
    elsif gs + c + ds == 0
      row.concat(Array.new(4, "100%"))
    else
      row.concat(Array.new(4, nil))
      puts "#{school['name']} not enough statistical data"
    end

    row << notes.join("\n")
    csv << row
  end
end

puts
puts '=' * 100
puts 'Calculating Grouped Retention Rates'.bold
puts '=' * 100
CSV.open("#{dir}/grouped_retention.csv", 'wb') do |csv|
  csv << [
    'Group Name',
    'Group Type',
    'Number Schools',
    "#{PREVIOUS_YEAR} Total Children",
    "#{CURRENT_YEAR} Total Children",
    'Graduated from School',
    'Graduated from School and Continued in Network',
    'Continued',
    'Continued at School',
    'Continued in Network',
    'Continued at School (Kindergarten Eligible)',
    'Continued in Network (Kindergarten Eligible)',
    'Continued at School (Infant/Toddler Eligible)',
    'Continued in Network (Infant/Toddler Eligible)',
    'Continued at School (Kindergarten or Infant/Toddler Eligible)',
    'Continued in Network (Kindergarten or Infant/Toddler Eligible)',
    'Dropped School',
    'Dropped School but Continued in Network',
    'Dropped School (Kindergarten Eligible)',
    'Dropped School but Continued in Network (Kindergarten Eligible)',
    'Dropped School (Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Infant/Toddler Classrooms)',
    'Dropped School (Kindergarten or Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Kindergarten or Infant/Toddler Classrooms)',
    'Retention Rate (schools)',
    'Retention Rate (schools: Ignoring Kindergarten Eligible)',
    'Retention Rate (schools: Ignoring Toddler/Infant Classrooms)',
    'Retention Rate (schools: Ignoring Kindergarten and Toddler/Infant Classrooms)',
    'Retention Rate (network)',
    'Retention Rate (network: Ignoring Kindergarten Eligible)',
    'Retention Rate (network: Ignoring Toddler/Infant Classrooms)',
    'Retention Rate (network: Ignoring Kindergarten and Toddler/Infant Classrooms)',
    'Notes',
  ]

  # Helper for collecting a list of all school ids (unique) belonging to a provided grouping in the config.yml file
  collect_school_configs_for_group = lambda do |group_id|
    group = CONFIG['groupSchools'].find { |gs_config| gs_config['id'] == group_id }

    if group.nil?
      puts "Cannot find #{group_id} in Config files groupSchools list".red
      return []
    end

    school_configs = group['schools'] || []

    (group['groupIds'] || []).each do |gid|
      sub_group_configs = collect_school_configs_for_group.call(gid)
      school_configs.concat(sub_group_configs)
    end

    return school_configs.uniq { |s| s['id'] }
  end

  CONFIG['groupSchools'].each do |gs_config|
    notes = []

    group_school_configs = collect_school_configs_for_group.call(gs_config['id'])

    group_schools = group_school_configs.map do |gsc|
      school = schools.find { |s| s['id'] == gsc['id']}

      if school.nil?
        notes << "Unable to find school '#{gsc['name']}', not including in group"
      else
        if school['ignore']
          # notes << "School '#{school['name']}' in ignore list, not including in group"
          school = nil
        end
      end

      school
    end.compact

    group_stats = {tp:0, tc: 0, gs: 0, gsc: 0, c: 0, cs: 0, cn: 0, csk: 0, cnk: 0, csit: 0, cnit: 0, cskit: 0, cnkit: 0, ds:0, dscn: 0, dsk: 0, dscnk: 0, dsit: 0, dscnit: 0, dskit: 0, dscnkit: 0}
    group_schools.each do |school|
      school_stats = stats[school['id']]

      if school['previous_year']['sessions'].empty?
        notes << "Warning: School '#{school['name']}' has no #{PREVIOUS_YEAR} session"
      end
      if school['current_year']['sessions'].empty?
        notes << "Warning: School '#{school['name']}' has no #{CURRENT_YEAR} session"
      end
      if school_stats[:enrolled_previous_year].length == 0
        notes << "Warning: School '#{school['name']}' has no children enrolled in previous year (not including ignored children)"
      end
      if school_stats[:enrolled_current_year].length == 0
        notes << "Warning: School '#{school['name']}' has no children enrolled in current year (not including ignored children)"
      end

      group_stats[:tp] += school_stats[:enrolled_previous_year].length
      group_stats[:tc] += school_stats[:enrolled_current_year].length
      group_stats[:gs] += school_stats[:graduated_school].length
      group_stats[:gsc] += school_stats[:graduated_school_and_continued_in_network].length
      group_stats[:c] += school_stats[:continued].length
      group_stats[:cs] += school_stats[:continued_at_school].length
      group_stats[:cn] += school_stats[:continued_in_network].length
      group_stats[:csk] += school_stats[:continued_at_school_kindergarten].length
      group_stats[:cnk] += school_stats[:continued_in_network_kindergarten].length
      group_stats[:csit] += school_stats[:continued_at_school_infant_toddler].length
      group_stats[:cnit] += school_stats[:continued_in_network_infant_toddler].length
      group_stats[:cskit] += school_stats[:continued_at_school_kindergarten_or_infant_toddler].length
      group_stats[:cnkit] += school_stats[:continued_in_network_kindergarten_or_infant_toddler].length
      group_stats[:ds] += school_stats[:dropped_school].length
      group_stats[:dscn] += school_stats[:dropped_school_but_continued_in_network].length
      group_stats[:dsk] += school_stats[:dropped_school_kindergarten].length
      group_stats[:dscnk] += school_stats[:dropped_school_but_continued_in_network_kindergarten].length
      group_stats[:dsit] += school_stats[:dropped_school_infant_toddler].length
      group_stats[:dscnit] += school_stats[:dropped_school_but_continued_in_network_infant_toddler].length
      group_stats[:dskit] += school_stats[:dropped_school_kindergarten_or_infant_toddler].length
      group_stats[:dscnkit] += school_stats[:dropped_school_but_continued_in_network_kindergarten_or_infant_toddler].length
    end

    row = [gs_config['name'], gs_config['type'], group_schools.count, group_stats[:tp], group_stats[:tc], group_stats[:gs], group_stats[:gsc], group_stats[:c], group_stats[:cs], group_stats[:cn], group_stats[:csk], group_stats[:cnk], group_stats[:csit], group_stats[:cnit], group_stats[:cskit], group_stats[:cnkit], group_stats[:ds], group_stats[:dscn], group_stats[:dsk], group_stats[:dscnk], group_stats[:dsit], group_stats[:dscnit], group_stats[:dskit], group_stats[:dscnkit]]

    # School retention
    if (group_stats[:cs] + group_stats[:ds]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs] * 100.0 / (group_stats[:cs] + group_stats[:ds])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) not enough statistical data"
    end

    # School retention ignoring Kindergarten
    if (group_stats[:cs] - group_stats[:csk] + group_stats[:ds] - group_stats[:dsk]) > 0
      rate = ((group_stats[:cs] - group_stats[:csk]) * 100.0 / (group_stats[:cs] - group_stats[:csk] + group_stats[:ds] - group_stats[:dsk])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten - not enough statistical data"
    end

    # School retention ignoring Infant Toddler
    if (group_stats[:cs] - group_stats[:csit] + group_stats[:ds] - group_stats[:dsit]) > 0
      rate = ((group_stats[:cs] - group_stats[:csit]) * 100.0 / (group_stats[:cs] - group_stats[:csit] + group_stats[:ds] - group_stats[:dsit])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Infant/Toddler => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Infant/Toddler - not enough statistical data"
    end

    # School retention ignoring Kindergarten and Infant Toddler
    if (group_stats[:cs] - group_stats[:cskit] + group_stats[:ds] - group_stats[:dskit]) > 0
      rate = ((group_stats[:cs] - group_stats[:cskit]) * 100.0 / (group_stats[:cs] - group_stats[:cskit] + group_stats[:ds] - group_stats[:dskit])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten and Infant/Toddler => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten and Infant/Toddler - not enough statistical data"
    end

    # Network retention
    if (group_stats[:c] + group_stats[:ds] - group_stats[:dscn]) > 0 # computing network retention rate (taking into account retention within network)
      rate = (group_stats[:c] * 100.0 / (group_stats[:c] + group_stats[:ds] - group_stats[:dscn])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) not enough statistical data"
    end

    # Network retention ignoring Kindergarten
    if (group_stats[:c] - group_stats[:csk] - group_stats[:cnk] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnk]) - group_stats[:dsk]) > 0
      rate = ((group_stats[:c] - group_stats[:csk] - group_stats[:cnk]) * 100.0 / (group_stats[:c] - group_stats[:csk] - group_stats[:cnk] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnk]) - group_stats[:dsk])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten=> #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten - not enough statistical data"
    end

    # Network retention ignoring Infant Toddler
    if (group_stats[:c] - group_stats[:csit] - group_stats[:cnit] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnit]) - group_stats[:dsit]) > 0
      rate = ((group_stats[:c] - group_stats[:csit] - group_stats[:cnit]) * 100.0 / (group_stats[:c] - group_stats[:csit] - group_stats[:cnit] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnit]) - group_stats[:dsit])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Infant/Toddler=> #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Infant/Toddler - not enough statistical data"
    end

    # Network retention ignoring Kindergarten and Infant Toddler
    if (group_stats[:c] - group_stats[:cskit] - group_stats[:cnkit] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnkit]) - group_stats[:dskit]) > 0
      rate = ((group_stats[:c] - group_stats[:cskit] - group_stats[:cnkit]) * 100.0 / (group_stats[:c] - group_stats[:cskit] - group_stats[:cnkit] + group_stats[:ds] - (group_stats[:dscn] - group_stats[:dscnkit]) - group_stats[:dskit])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten & Infant/Toddler=> #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) Kindergarten & Infant/Toddler - not enough statistical data"
    end

    puts "#{gs_config['name']} (#{gs_config['type']}) Notes: #{notes.join(', ')}"

    row << notes.join("\n")
    csv << row
  end
end