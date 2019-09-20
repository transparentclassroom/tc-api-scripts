require 'base64'
require 'colorize'
require 'csv'
require 'yaml'
require_relative './lib/transparent_classroom/client'

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

def load_schools(tc)
  schools = tc.get 'schools.json'
  schools.reject! do |school|
    CONFIG['rejectSchools'].any? do |ignore|
      school['name'] == ignore['name'] || school['id'] == ignore['id']
    end
  end
  schools.each do |school|
    school['ignore'] = false

    CONFIG['ignoreSchools'].any? do |ignore|
      if school['name'] == ignore['name'] or school['id'] == ignore['id']
        school['ignore'] = true
      end
    end
  end
  schools
end

def load_classrooms_by_id(tc, school)
  tc.school_id = school['id']

  classrooms = tc.get 'classrooms.json'
  classrooms.each do |c|
    c['ignore'] = false

    CONFIG['ignoreClassrooms'].any? do |ignore|
      if ignore['schoolId'] == school['id'] or ignore['schoolName'] == school['name']
        ignore['classrooms'].any? do |ignoreClassroom|
          if ignoreClassroom['id'] == c['id'] || ignoreClassroom['name'] == c['name']
            c['ignore'] = true
          end
        end
      end
    end
  end

  classrooms.index_by { |c| c['id'] }
end

def load_children(tc, school, session)
  tc.school_id = school['id']

  children = tc.get 'children.json', params: { session_id: session['id'] }
  children.each { |c| c['school'] = school['name'] }

  children.each do |c|
    c['ignore'] = false

    CONFIG['ignoreChildren'].any? do |ignore|
      if ignore['schoolId'] == school['id'] or ignore['schoolName'] == school['name']
        ignore['children'].any? do |ignoreChildren|
          if ignoreChildren['id'] == c['id'] || ignoreChildren['name'] == c['name']
            c['ignore'] = true
          end
        end
      end
    end
  end

  children
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

def too_old?(classroom, age)
  if classroom.nil?
    return false
  end

  case classroom['level']
    when '0-1.5'
      age >= to_age(years: 1, months: 6)
    when '1.5-3', '0-3'
      age >= to_age(years: 3)
    when '3-6'
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
      puts "don't know how to handle level #{classroom['level']}".red
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
  classrooms = child['classroom_ids'].map { |id| child['school']['classrooms_by_id'][id] }.compact
  classrooms.reject {|c| c['ignore']}
end

def get_child_ignored_classrooms(child)
  classrooms = child['classroom_ids'].map { |id| child['school']['classrooms_by_id'][id] }.compact
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

def is_child_ignored(child)
  child_ignored_list(child).values.reduce(false) { |agg, reason| agg || reason }
end

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
tc.masquerade_id = 50612 # cam

schools = load_schools(tc)

#schools = schools[0..4]
#schools.reject! {|s| s['name'] != 'Snowdrop Montessori' and s['name'] != 'Wildflower Montessori'}
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

    parse_date_from_year_and_day = lambda do |split_year, day|
      return Date.parse("#{split_year}/#{day}")
    end

    latest_start = parse_date_from_year_and_day.call(school_year.split('-')[0], SCHOOL_YEAR_LATEST_START)
    earliest_stop = parse_date_from_year_and_day.call(school_year.split('-')[1], SCHOOL_YEAR_EARLIEST_STOP)

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
    'Classroom',
    'Level',
    "Start of #{CURRENT_YEAR}",
    "End of #{CURRENT_YEAR}",
    "Age at Start of #{CURRENT_YEAR}",
    "Age in Months at Start of #{CURRENT_YEAR}",
    "Enrolled in #{CURRENT_YEAR}",
    "Enrolled in #{PREVIOUS_YEAR}",
    "Enrolled at Different School in #{PREVIOUS_YEAR}",
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

      ignored = is_child_ignored(child)
      if ignored
        notes.concat(reasons_child_ignored_details(child))
      end

      classroom = get_child_active_classroom(child)

      is_currently_enrolled_in_network = current_years_children.has_key?(child['fingerprint']) && not(is_child_ignored(child))
      was_previously_enrolled_in_network = previous_years_children.has_key?(child['fingerprint']) && not(is_child_ignored(child))
      was_previously_at_current_school = previous_year['children'].any? {|c| c['fingerprint'] == child['fingerprint'] && not(is_child_ignored(c))}
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
          start_date,
          stop_date,
          format_age(age_on(child, start_date)),
          age_on(child, start_date),
          is_currently_enrolled_in_network,
          was_previously_enrolled_in_network,
          was_previously_at_different_school,
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
    'Classroom',
    'Level',
    "Start of #{CURRENT_YEAR}",
    "Age at Start of #{CURRENT_YEAR}",
    "Age in Months at Start of #{CURRENT_YEAR}",
    "Enrolled in #{PREVIOUS_YEAR}",
    "Enrolled in #{CURRENT_YEAR}",
    "Enrolled at Different School in #{CURRENT_YEAR}",
    "Aging out of level",
    "Ignored",
    'Notes',
  ]

  puts
  puts '=' * 100
  puts "Seeing which children from #{PREVIOUS_YEAR} are continuing".bold
  puts '=' * 100
  schools.each do |school|
    #next if (current_year = school['current_year'])['sessions'].empty? || (previous_year = school['previous_year'])['sessions'].empty?
    current_year = school['current_year']
    previous_year = school['previous_year']

    stats[school['id']] = school_stats = {
      graduating: [],
      continuing: [],
      continuing_at_school: [],
      continuing_in_network: [],
      dropping: [],
      enrolledCurrentYear: current_year['children'].reject{ |c| is_child_ignored(c) },
      enrolledPreviousYear: previous_year['children'].reject{ |c| is_child_ignored(c) },
    }

    next if previous_year['children'].empty?

    puts school['name'].bold

    start_date = Date.parse(current_year['start_date'])

    previous_year['children'].each do |child|
      notes = []

      ignored = is_child_ignored(child)
      if ignored
        notes.concat(reasons_child_ignored_details(child))
      end

      classroom = get_child_active_classroom(child)

      was_previously_enrolled_in_network = previous_years_children.has_key?(child['fingerprint']) && not(is_child_ignored(child))
      is_continuing_in_network = current_years_children.has_key?(child['fingerprint']) && not(is_child_ignored(child))
      is_continuing_at_current_school = current_year['children'].any? {|c| c['fingerprint'] == child['fingerprint'] && not(is_child_ignored(c))}
      is_continuing_at_different_school = is_continuing_in_network && not(is_continuing_at_current_school)

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
        start_date,
        format_age(age_on(child, start_date)),
        age_on(child, start_date),
        was_previously_enrolled_in_network,
        is_continuing_in_network,
        is_continuing_at_different_school,
        too_old?(classroom, age_on(child, start_date)) ? 'Y' : 'N',
        ignored ? 'Y' : 'N',
        notes.join("\n"),
      ]

      # Do not compute stats on ignored children
      if ignored
        next
      end

      if too_old?(classroom, age_on(child, start_date))
        school_stats[:graduating] << child
      # TODO: The next elsif test is analyzing the whole network, when computing retention within the school is this the right test?
      # elsif current_years_children.has_key?(fingerprint(child))
      elsif is_continuing_in_network || is_continuing_at_current_school
        school_stats[:continuing] << child

        if is_continuing_at_current_school
          school_stats[:continuing_at_school] << child
        elsif is_continuing_in_network
          school_stats[:continuing_in_network] << child
        end
      else
        school_stats[:dropping] << child
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
    'Graduating',
    'Continuing',
    'Continuing at School',
    'Continuing in Network',
    'Dropping',
    'Retention Rate',
    'Notes',
  ]
  stats.each do |school_id, school_stats|
    school = schools.find{ |s| s['id'] == school_id }
    tp, tc, g, c, d = school_stats[:enrolledPreviousYear].length, school_stats[:enrolledCurrentYear].length, school_stats[:graduating].length, school_stats[:continuing].length, school_stats[:dropping].length
    row = [school['name'], tp, tc, g, c, school_stats[:continuing_at_school].length, school_stats[:continuing_in_network].length, d]
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
      row << nil
      puts "#{school['name']} not enough session/children data: #{notes.join(', ')}"
    elsif c + d > 0
      rate = c * 100 / (c + d)
      row << "#{rate}%"
      puts "#{school['name']} => #{rate}% #{notes.join(', ')}"
    elsif g + c + d == 0
      raw << "100%"
    else
      row << nil
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
    'Graduating',
    'Continuing',
    'Continuing at School',
    'Continuing in Network',
    'Dropping',
    'Retention Rate',
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

    group_stats = {tp:0, tc: 0, g: 0, c: 0, cs: 0, cn: 0, d:0}
    group_schools.each do |school|
      school_stats = stats[school['id']]

      if school['previous_year']['sessions'].empty?
        notes << "Warning: School '#{school['name']}' has no #{PREVIOUS_YEAR} session"
      end
      if school['current_year']['sessions'].empty?
        notes << "Warning: School '#{school['name']}' has no #{CURRENT_YEAR} session"
      end
      if school_stats[:enrolledPreviousYear].length == 0
        notes << "Warning: School '#{school['name']}' has no children enrolled in previous year (not including ignored children)"
      end
      if school_stats[:enrolledCurrentYear].length == 0
        notes << "Warning: School '#{school['name']}' has no children enrolled in current year (not including ignored children)"
      end

      group_stats[:tp] += school_stats[:enrolledPreviousYear].length
      group_stats[:tc] += school_stats[:enrolledCurrentYear].length
      group_stats[:g] += school_stats[:graduating].length
      group_stats[:c] += school_stats[:continuing].length
      group_stats[:cs] += school_stats[:continuing_at_school].length
      group_stats[:cn] += school_stats[:continuing_in_network].length
      group_stats[:d] += school_stats[:dropping].length
    end

    row = [gs_config['name'], gs_config['type'], group_schools.count, group_stats[:tp], group_stats[:tc], group_stats[:g], group_stats[:c], group_stats[:cs], group_stats[:cn], group_stats[:d]]

    if group_stats[:c] + group_stats[:d] > 0
      rate = group_stats[:c] * 100 / (group_stats[:c] + group_stats[:d])
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) => #{rate}% #{notes.join(', ')}"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) not enough statistical data: #{notes.join(', ')}"
    end

    row << notes.join("\n")
    csv << row
  end
end