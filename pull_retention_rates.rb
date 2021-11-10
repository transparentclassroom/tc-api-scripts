require 'base64'
require 'colorize'
require 'csv'
require 'date'
require 'yaml'
require_relative 'lib/data_mapper/mapper'
require_relative './lib/transparent_classroom/client'
require_relative './lib/name_matcher/matcher'

PREVIOUS_YEAR = '2020-21'
CURRENT_YEAR = '2021-22'

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
    'graduatedChildren' => [],
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

def is_child_ignored(child)
  classroom_ids=child['classroom_ids']
  school = child['school']

  is_child_school_ignored = is_school_ignored(school['id'], school['name'])

  are_all_child_classrooms_ignored = classroom_ids.all? do |classroom_id|
    is_classroom_ignored(school['id'], classroom_id, school['name'])
  end

  is_child_explicitly_ignored = CONFIG['ignoreChildren'].any? do |ignore|
    if ignore['schoolId'] == school['id'] or ignore['schoolName'] == school['name']
      ignore['children'].any? do |ignoreChildren|
        ignoreChildren['id'] == child['id'] || ignoreChildren['name'] == name(child)
      end
    end
  end

  is_child_age_ignored = age_on(child, Date.parse(school['current_year']['start_date'])) >= to_age(years: 21, months: 0)

  is_child_school_ignored || are_all_child_classrooms_ignored || is_child_explicitly_ignored || is_child_age_ignored
end

def is_child_included_in_graduated_override_config(school_id, child_id, school_name=nil, child_name=nil)
  is_child_in_graduated_config = CONFIG['graduatedChildren'].any? do |graduated|
    if graduated['schoolId'] == school_id or graduated['schoolName'] == school_name
      graduated['children'].any? do |ignoreChildren|
        ignoreChildren['id'] == child_id || ignoreChildren['name'] == child_name
      end
    end
  end
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

  children.each do |child|
    child['school'] = school

    child['ignore'] = is_child_ignored(child=child)

    child['graduated_teacher'] = child.has_key?('exit_reason') && child['exit_reason'].downcase == "graduated"
    child['graduated_parent'] = nil
    child['exit_survey'] = nil
    child['parent_exit_reason'] = nil
    child['ethnicity_original'] = child['ethnicity'].clone
    child['ethnicity_survey_original'] = nil
    if child.has_key?('exit_survey_id') && child['exit_survey_id'] != nil
      exit_survey_response = tc.get("forms/#{child['exit_survey_id']}.json")

      child['exit_survey'] = exit_survey_response
      child['parent_exit_reason'] = nil
      if exit_survey_response['state'] == "submitted" && exit_survey_response.has_key?('fields') && exit_survey_response['fields'].has_key?('Reason for Leaving')
        child['parent_exit_reason'] = exit_survey_response['fields']["Reason for Leaving"]
        child['graduated_parent'] = exit_survey_response['fields']["Reason for Leaving"].downcase == "graduated"
      end
    end

    child['graduated_override'] = is_child_included_in_graduated_override_config(
        school_id=school['id'],
        child_id=child['id'],
        school_name=school['name'],
        child_name=name(child)
    )

    child['fingerprint'] = fingerprint(child)
  end

  children
end

def load_network_family_survey_form_templates(tc)
  tc.school_id = nil

  forms = tc.get("form_templates.json")
  network_forms = forms.map do |f|
    network_template_id = f['id']
    network_template_name = f['name']

    if network_template_name =~ /family survey/i
      {
        network_template_id: network_template_id,
        network_template_name: network_template_name,
        is_family_survey: true
      }
    else
      nil
    end
  end

  network_forms.compact
end

def load_school_family_survey_form_templates(tc, network_family_survey_forms, school)
  tc.school_id = school['id']

  network_family_survey_ids = network_family_survey_forms.map{|f| f[:network_template_id]}
  forms = tc.get("form_templates.json")
  school_forms = forms.map do |f|
    school_template_id = f['id']
    school_template_name = f['name']

    is_family_survey_school_template = false
    f['widgets'].each do |w|
      if w['type'] == 'EmbeddedForm' && network_family_survey_ids.include?(w['embedded_form_id'].to_i)
        is_family_survey_school_template = true
        break
      end
    end

    if is_family_survey_school_template
      {
        school_template_id: school_template_id,
        school_template_name: school_template_name,
        is_family_survey: is_family_survey_school_template
      }
    else
      nil
    end
  end

  school_forms.compact
end

def load_school_family_survey_form_data(tc, school_family_survey_form_templates, school)
  tc.school_id = school['id']

  school_family_survey_ids = school_family_survey_form_templates.map{|f| f[:school_template_id]}

  form_data_by_child = {}
  school_family_survey_ids.each do |f_id|
    form_responses = tc.get("forms.json", params: { form_template_id: f_id })
    form_responses.each do |fr|
      unless form_data_by_child.has_key?(fr['child_id'])
        form_data_by_child[fr['child_id']] = []
      end

      form_data = {
        'form_id': fr['id'],
        'state': fr['state'],
        'created_at_text': fr['created_at'],
        'updated_at_text': fr['updated_at'],
        'student_id': fr['child_id'],
        'school_id': school['id']
      }
      fields = fr['fields']
      fields.each do | key, value |
        if !value.nil? && DataMapper.field_names_has_key?(key)
          form_data[DataMapper.field_names_value_for(key).to_sym] = value
        end
      end

      form_data_by_child[fr['child_id']].append(form_data)
    end
  end

  form_data_by_child
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

def get_school_from_name(school_name, schools)
  match = schools.detect do |school|
    break school if school['name'].strip.downcase == school_name.strip.downcase
  end

  match
end

def get_classroom_from_name(classroom_name, schools)
  classroom = schools.detect do |school|
    c = school['classrooms_by_id'].detect do |_, classroom|
      break classroom if classroom['name'].strip.downcase == classroom_name.strip.downcase
    end

    break c if c
  end

  classroom
end

def load_missing_children_from_csv(schools)
  return [] unless File.file?("missing_children.csv")

  missing = CSV.parse(File.read("missing_children.csv"), headers: true)

  children = missing.map do |raw|
    child = {
        'id' => raw['child_id'].to_i,
        'school' => get_school_from_name(raw['school_name'], schools),
        'first_name' => raw['first_name'],
        'last_name' => raw['last_name'],
        'birth_date' => raw['birth_date'],
        'ethnicity' => (raw['ethnicity'] || '').split(","),
        'household_income' => raw['household_income'],
        'dominant_language' => raw['dominant_language'],
        'classroom_ids' => raw['classroom_names'].split(",").map{|name| c = get_classroom_from_name(name, schools); c ? c['id'].to_i : nil }.compact,
        'was_missing' => true
    }
    child['fingerprint'] = fingerprint(child)

    child
  end

  # Scrub records that could not be associated with a school
  children.reject!{|child| child['school'].nil?}

  children.each do |child|
    child['ignore'] = is_child_ignored(child=child)
  end

  children
end

dir = File.expand_path("output", File.dirname(__FILE__))
FileUtils.mkdir_p(dir) unless File.directory?(dir)

tc = TransparentClassroom::Client.new
tc.masquerade_id = ENV['TC_MASQUERADE_ID']

schools = load_schools(tc)
network_family_survey_forms = load_network_family_survey_form_templates(tc)

#schools = schools[4..8]
#schools.reject! {|s| s['name'] != 'Cosmos Montessori'}
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
      load_children(tc, school, session)
    end.flatten

    children.each do |child|
      if school['forms_by_child_id'].keys.include?(child['id'])
        child_forms = school['forms_by_child_id'][child['id']]
        child_latest_form = child_forms.max_by { |f| Date.strptime(f[:created_at_text]) }

        if child_latest_form.has_key?(:ethnicity_response)
          child['ethnicity_survey_original'] = child_latest_form[:ethnicity_response].clone
          unless child_latest_form[:ethnicity_response].nil? ||
             child_latest_form[:ethnicity_response] == "" ||
             child_latest_form[:ethnicity_response] == []
            child['ethnicity'] = child_latest_form[:ethnicity_response]
          end
        end

        if child_latest_form.has_key?(:household_income_response)
          child['household_income'] = child_latest_form[:household_income_response]
        end

        if child_latest_form.has_key?(:language_response)
          child['dominant_language'] = child_latest_form[:language_response]
        end
      end

      if child['ethnicity'].nil?
        child['ethnicity'] = []
      else
        child['ethnicity'] = DataMapper.ethnicities_value_for(child['ethnicity'])
      end

      if child['household_income'].nil?
        child['household_income'] = []
      else
        child['household_income'] = DataMapper.income_value_for(child['household_income'])
      end

      if child['dominant_language'].nil?
        child['dominant_language'] = []
      else
        child['dominant_language'] = DataMapper.languages_value_for(child['dominant_language'])
      end

      child['is_afam'] = child['ethnicity'].include?('African-American, Afro-Caribbean or Black')
      child['is_asam'] = child['ethnicity'].include?('Asian-American')
      child['is_latinx'] = child['ethnicity'].include?('Hispanic, Latinx, or Spanish Origin')
      child['is_me'] = child['ethnicity'].include?('Middle Eastern or North African')
      child['is_natam'] = child['ethnicity'].include?('Native American or Alaska Native')
      child['is_pi'] = child['ethnicity'].include?('Native Hawaiian or Other Pacific Islander')
      child['is_white'] = child['ethnicity'].include?('White')
      child['is_white_only'] = child['is_white'] && child['ethnicity'].length == 1
      child['is_other_nonwhite'] = child['ethnicity'].include?('Other (non-white)')
      child['is_mixed'] = child['ethnicity'].include?('Unspecified multiple ethnicities')
      is_gom = child['is_afam'] || child['is_asam'] || child['is_latinx'] || child['is_me'] || child['is_natam'] || child['is_pi'] || child['is_other_nonwhite'] || child['is_mixed']
      child['is_gom'] = (is_gom == 1 || is_gom == true)
      is_afam_latinx = child['is_afam'] || child['is_latinx']
      child['is_afam_latinx'] = (is_afam_latinx == 1 || is_afam_latinx == true)

      child['is_low_income'] = child['household_income'] == 'Low'
      child['is_medium_income'] = child['household_income'] == 'Medium'
      child['is_high_income'] = child['household_income'] == 'High'
    end

    children.uniq { |c| c['id'] }
  end

  puts
  puts "Loading Family Survey Forms"
  puts '-' * 100
  school_form_templates = load_school_family_survey_form_templates(tc, network_family_survey_forms, school)
  school['forms_by_child_id'] = load_school_family_survey_form_data(tc, school_form_templates, school)

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
puts "Adding Missing Children to #{PREVIOUS_YEAR}".bold
puts '=' * 100
missing_children = load_missing_children_from_csv(schools)

puts
puts "Organizing Collection of All Children for #{PREVIOUS_YEAR}".bold
puts '=' * 100
previous_years_children = {}
schools.each do |school|
  fids = school['previous_year']['children'].map do |child|
    child['fingerprint']
  end

  child_ids = school['previous_year']['children'].map do |child|
    child['id']
  end

  missing_children_for_school = missing_children.find_all do |missing|
    school['id'] == missing['school']['id']
  end

  missing_children_for_school.each do |missing|
    unless fids.include?(missing['fingerprint']) || child_ids.include?(missing['id'])
      puts "Adding child from missing_children.csv: #{name(missing)} (#{missing['id']}) - #{missing['school']['name']} - #{missing['classroom_ids']}".yellow
      school['previous_year']['children'] << missing
    end
  end

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
    'Ethnicity Original',
    'Ethnicity Survey',
    'Ethnicity Normalized',
    'Is AFAM',
    'Is ASAM',
    'Is Latinx',
    'Is ME',
    'Is NATAM',
    'Is PI',
    'Is White',
    'Is Mixed',
    'Is GOM',
    'Is AFAM Latinx',
    'Household Income',
    'Is Low Income',
    'Is Medium Income',
    'Is High Income',
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
          child['ethnicity_original'],
          child['ethnicity_survey_original'],
          "[#{child['ethnicity']&.map{|v| "\"#{v}\""}.join(", ")}]",
          child['is_afam'],
          child['is_asam'],
          child['is_latinx'],
          child['is_me'],
          child['is_natam'],
          child['is_pi'],
          child['is_white'],
          child['is_mixed'],
          child['is_gom'],
          child['is_afam_latinx'],
          child['household_income'],
          child['is_low_income'],
          child['is_medium_income'],
          child['is_high_income'],
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
          too_old?(classroom, age_on(child, stop_date)),
          ignored,
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
    'Ethnicity Original',
    'Ethnicity Survey',
    'Ethnicity Normalized',
    'Is AFAM',
    'Is ASAM',
    'Is Latinx',
    'Is ME',
    'Is NATAM',
    'Is PI',
    'Is White',
    'Is Mixed',
    'Is GOM',
    'Is AFAM Latinx',
    'Household Income',
    'Is Low Income',
    'Is Medium Income',
    'Is High Income',
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
    'Exit Reason (teacher)',
    'Graduated According to Teacher',
    'Exit Reason (parent)',
    'Graduated According to Parent',
    'Ignored',
    'Added Manually (previously deleted from TC)',
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
      graduated_school_gom: [],
      graduated_school_white: [],
      graduated_school_low_income: [],
      graduated_school_medium_income: [],
      graduated_school_high_income: [],
      graduated_school_and_continued_in_network: [],
      graduated_school_and_continued_in_network_gom: [],
      graduated_school_and_continued_in_network_white: [],
      graduated_school_and_continued_in_network_low_income: [],
      graduated_school_and_continued_in_network_medium_income: [],
      graduated_school_and_continued_in_network_high_income: [],
      continued: [],
      continued_gom: [],
      continued_white: [],
      continued_low_income: [],
      continued_medium_income: [],
      continued_high_income: [],
      continued_at_school: [],
      continued_at_school_gom: [],
      continued_at_school_white: [],
      continued_at_school_low_income: [],
      continued_at_school_medium_income: [],
      continued_at_school_high_income: [],
      continued_in_network: [],
      continued_in_network_gom: [],
      continued_in_network_white: [],
      continued_in_network_low_income: [],
      continued_in_network_medium_income: [],
      continued_in_network_high_income: [],
      continued_at_school_kindergarten: [],
      continued_in_network_kindergarten: [],
      continued_at_school_infant_toddler: [],
      continued_in_network_infant_toddler: [],
      continued_at_school_kindergarten_or_infant_toddler: [],
      continued_in_network_kindergarten_or_infant_toddler: [],
      dropped_school: [],
      dropped_school_gom: [],
      dropped_school_white: [],
      dropped_school_low_income: [],
      dropped_school_medium_income: [],
      dropped_school_high_income: [],
      dropped_school_but_continued_in_network: [],
      dropped_school_but_continued_in_network_gom: [],
      dropped_school_but_continued_in_network_white: [],
      dropped_school_but_continued_in_network_low_income: [],
      dropped_school_but_continued_in_network_medium_income: [],
      dropped_school_but_continued_in_network_high_income: [],
      dropped_school_kindergarten: [],
      dropped_school_but_continued_in_network_kindergarten: [],
      dropped_school_infant_toddler: [],
      dropped_school_but_continued_in_network_infant_toddler: [],
      dropped_school_kindergarten_or_infant_toddler: [],
      dropped_school_but_continued_in_network_kindergarten_or_infant_toddler: [],
      enrolled_current_year: current_year['children'].reject{ |c| c['ignore'] },
      enrolled_current_year_gom: [],
      enrolled_current_year_white: [],
      enrolled_current_year_low_income: [],
      enrolled_current_year_medium_income: [],
      enrolled_current_year_high_income: [],
      enrolled_previous_year: previous_year['children'].reject{ |c| c['ignore'] },
      enrolled_previous_year_gom: [],
      enrolled_previous_year_white: [],
      enrolled_previous_year_low_income: [],
      enrolled_previous_year_medium_income: [],
      enrolled_previous_year_high_income: [],
      exit_reason_teacher_graduated: [],
      exit_reason_teacher_relocated: [],
      exit_reason_teacher_expense: [],
      exit_reason_teacher_hours_offered: [],
      exit_reason_teacher_location: [],
      exit_reason_teacher_eligible_for_kindergarten: [],
      exit_reason_teacher_asked_to_leave: [],
      exit_reason_teacher_joined_sibling: [],
      exit_reason_teacher_no_lottery_spot: [],
      exit_reason_teacher_bad_fit: [],
      exit_reason_teacher_equity: [],
      exit_reason_teacher_family_dissatisfied: [],
      exit_reason_teacher_natural_disaster: [],
      exit_reason_teacher_entered_public_system: [],
      exit_reason_teacher_transferred_multi_year: [],
      exit_reason_parent_graduated: [],
      exit_reason_parent_relocated: [],
      exit_reason_parent_expense: [],
      exit_reason_parent_hours_offered: [],
      exit_reason_parent_location: [],
      exit_reason_parent_eligible_for_kindergarten: [],
      exit_reason_parent_asked_to_leave: [],
      exit_reason_parent_joined_sibling: [],
      exit_reason_parent_no_lottery_spot: [],
      exit_reason_parent_bad_fit: [],
      exit_reason_parent_equity: [],
      exit_reason_parent_family_dissatisfied: [],
      exit_reason_parent_natural_disaster: [],
      exit_reason_parent_entered_public_system: [],
      exit_reason_parent_transferred_multi_year: []
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

      graduated_override = child['graduated_override']
      if graduated_override
        notes << "Child marked graduated manually"
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

      is_continued_at_current_school = is_currently_enrolled_in_network && child['school']['id'] == current_year_child_match['school']['id']
      is_continued_at_different_school = is_currently_enrolled_in_network && not(is_continued_at_current_school)

      graduated_school = graduated_override || child['graduated_teacher'] || (!age_appropriate_for_school?(school, age_on(child, start_date)) && !is_continued_at_current_school)
      dropped_school = !graduated_school && age_appropriate_for_school?(school, age_on(child, start_date)) && !is_continued_at_current_school

      csv << [
        child['id'],
        school['name'],
        child['first_name'],
        child['last_name'],
        child['birth_date'],
        child['ethnicity_original'],
        child['ethnicity_survey_original'],
        "[#{child['ethnicity']&.map{|v| "\"#{v}\""}.join(", ")}]",
        child['is_afam'],
        child['is_asam'],
        child['is_latinx'],
        child['is_me'],
        child['is_natam'],
        child['is_pi'],
        child['is_white'],
        child['is_mixed'],
        child['is_gom'],
        child['is_afam_latinx'],
        child['household_income'],
        child['is_low_income'],
        child['is_medium_income'],
        child['is_high_income'],
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
        too_old?(classroom, age_on(child, start_date)),
        age_appropriate_for_school?(school, age_on(child, start_date)),
        graduated_school,
        is_continued_at_current_school,
        is_currently_enrolled_in_network,
        dropped_school,
        is_child_kindergarten_eligible,
        child['exit_reason'],
        child['graduated_teacher'],
        child['parent_exit_reason'],
        child['graduated_parent'],
        ignored,
        child['was_missing'] || false,
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

      school_stats[:enrolled_previous_year_gom] = school_stats[:enrolled_previous_year].filter{|child| child['is_gom']}
      school_stats[:enrolled_previous_year_white] = school_stats[:enrolled_previous_year].filter{|child| child['is_white_only']}
      school_stats[:enrolled_previous_year_low_income] = school_stats[:enrolled_previous_year].filter{|child| child['is_low_income']}
      school_stats[:enrolled_previous_year_medium_income] = school_stats[:enrolled_previous_year].filter{|child| child['is_medium_income']}
      school_stats[:enrolled_previous_year_high_income] = school_stats[:enrolled_previous_year].filter{|child| child['is_high_income']}

      school_stats[:enrolled_current_year_gom] = school_stats[:enrolled_current_year].filter{|child| child['is_gom']}
      school_stats[:enrolled_current_year_white] = school_stats[:enrolled_current_year].filter{|child| child['is_white_only']}
      school_stats[:enrolled_current_year_low_income] = school_stats[:enrolled_current_year].filter{|child| child['is_low_income']}
      school_stats[:enrolled_current_year_medium_income] = school_stats[:enrolled_current_year].filter{|child| child['is_medium_income']}
      school_stats[:enrolled_current_year_high_income] = school_stats[:enrolled_current_year].filter{|child| child['is_high_income']}

      school_stats[:graduated_school_gom] = school_stats[:graduated_school].filter{|child| child['is_gom']}
      school_stats[:graduated_school_white] = school_stats[:graduated_school].filter{|child| child['is_white_only']}
      school_stats[:graduated_school_low_income] = school_stats[:graduated_school].filter{|child| child['is_low_income']}
      school_stats[:graduated_school_medium_income] = school_stats[:graduated_school].filter{|child| child['is_medium_income']}
      school_stats[:graduated_school_high_income] = school_stats[:graduated_school].filter{|child| child['is_high_income']}

      school_stats[:graduated_school_and_continued_in_network_gom] = school_stats[:graduated_school_and_continued_in_network].filter{|child| child['is_gom']}
      school_stats[:graduated_school_and_continued_in_network_white] = school_stats[:graduated_school_and_continued_in_network].filter{|child| child['is_white_only']}
      school_stats[:graduated_school_and_continued_in_network_low_income] = school_stats[:graduated_school_and_continued_in_network].filter{|child| child['is_low_income']}
      school_stats[:graduated_school_and_continued_in_network_medium_income] = school_stats[:graduated_school_and_continued_in_network].filter{|child| child['is_medium_income']}
      school_stats[:graduated_school_and_continued_in_network_high_income] = school_stats[:graduated_school_and_continued_in_network].filter{|child| child['is_high_income']}

      school_stats[:continued_gom] = school_stats[:continued].filter{|child| child['is_gom']}
      school_stats[:continued_white] = school_stats[:continued].filter{|child| child['is_white_only']}
      school_stats[:continued_low_income] = school_stats[:continued].filter{|child| child['is_low_income']}
      school_stats[:continued_medium_income] = school_stats[:continued].filter{|child| child['is_medium_income']}
      school_stats[:continued_high_income] = school_stats[:continued].filter{|child| child['is_high_income']}

      school_stats[:continued_at_school_gom] = school_stats[:continued_at_school].filter{|child| child['is_gom']}
      school_stats[:continued_at_school_white] = school_stats[:continued_at_school].filter{|child| child['is_white_only']}
      school_stats[:continued_at_school_low_income] = school_stats[:continued_at_school].filter{|child| child['is_low_income']}
      school_stats[:continued_at_school_medium_income] = school_stats[:continued_at_school].filter{|child| child['is_medium_income']}
      school_stats[:continued_at_school_high_income] = school_stats[:continued_at_school].filter{|child| child['is_high_income']}

      school_stats[:continued_in_network_gom] = school_stats[:continued_in_network].filter{|child| child['is_gom']}
      school_stats[:continued_in_network_white] = school_stats[:continued_in_network].filter{|child| child['is_white_only']}
      school_stats[:continued_in_network_low_income] = school_stats[:continued_in_network].filter{|child| child['is_low_income']}
      school_stats[:continued_in_network_medium_income] = school_stats[:continued_in_network].filter{|child| child['is_medium_income']}
      school_stats[:continued_in_network_high_income] = school_stats[:continued_in_network].filter{|child| child['is_high_income']}

      school_stats[:dropped_school_gom] = school_stats[:dropped_school].filter{|child| child['is_gom']}
      school_stats[:dropped_school_white] = school_stats[:dropped_school].filter{|child| child['is_white_only']}
      school_stats[:dropped_school_low_income] = school_stats[:dropped_school].filter{|child| child['is_low_income']}
      school_stats[:dropped_school_medium_income] = school_stats[:dropped_school].filter{|child| child['is_medium_income']}
      school_stats[:dropped_school_high_income] = school_stats[:dropped_school].filter{|child| child['is_high_income']}

      school_stats[:dropped_school_but_continued_in_network_gom] = school_stats[:dropped_school_but_continued_in_network].filter{|child| child['is_gom']}
      school_stats[:dropped_school_but_continued_in_network_white] = school_stats[:dropped_school_but_continued_in_network].filter{|child| child['is_white_only']}
      school_stats[:dropped_school_but_continued_in_network_low_income] = school_stats[:dropped_school_but_continued_in_network].filter{|child| child['is_low_income']}
      school_stats[:dropped_school_but_continued_in_network_medium_income] = school_stats[:dropped_school_but_continued_in_network].filter{|child| child['is_medium_income']}
      school_stats[:dropped_school_but_continued_in_network_high_income] = school_stats[:dropped_school_but_continued_in_network].filter{|child| child['is_high_income']}

      if child.has_key?('exit_reason') && child['exit_reason'] != nil
        case child['exit_reason'].downcase
        when 'graduated'
          school_stats[:exit_reason_teacher_graduated] << child
        when 'relocated'
          school_stats[:exit_reason_teacher_relocated] << child
        when 'expense'
          school_stats[:exit_reason_teacher_expense] << child
        when 'hours_offered'
          school_stats[:exit_reason_teacher_hours_offered] << child
        when 'location'
          school_stats[:exit_reason_teacher_location] << child
        when 'eligible_for_kindergarten'
          school_stats[:exit_reason_teacher_eligible_for_kindergarten] << child
        when 'asked_to_leave'
          school_stats[:exit_reason_teacher_asked_to_leave] << child
        when 'joined_sibling'
          school_stats[:exit_reason_teacher_joined_sibling] << child
        when 'no_lottery_spot'
          school_stats[:exit_reason_teacher_no_lottery_spot] << child
        when 'bad_fit'
          school_stats[:exit_reason_teacher_bad_fit] << child
        when 'equity'
          school_stats[:exit_reason_teacher_equity] << child
        when 'family_dissatisfied'
          school_stats[:exit_reason_teacher_family_dissatisfied] << child
        when 'natural_disaster'
          school_stats[:exit_reason_teacher_natural_disaster] << child
        when 'entered_public_system'
          school_stats[:exit_reason_teacher_entered_public_system] << child
        when 'transferred_multi_year'
          school_stats[:exit_reason_teacher_transferred_multi_year] << child
        end
      end

      if child.has_key?('parent_exit_reason') && child['parent_exit_reason'] != nil
        case child['parent_exit_reason'].downcase
        when 'graduated'
          school_stats[:exit_reason_parent_graduated] << child
        when 'relocated'
          school_stats[:exit_reason_parent_relocated] << child
        when 'expense'
          school_stats[:exit_reason_parent_expense] << child
        when 'hours_offered'
          school_stats[:exit_reason_parent_hours_offered] << child
        when 'location'
          school_stats[:exit_reason_parent_location] << child
        when 'eligible_for_kindergarten'
          school_stats[:exit_reason_parent_eligible_for_kindergarten] << child
        when 'asked_to_leave'
          school_stats[:exit_reason_parent_asked_to_leave] << child
        when 'joined_sibling'
          school_stats[:exit_reason_parent_joined_sibling] << child
        when 'no_lottery_spot'
          school_stats[:exit_reason_parent_no_lottery_spot] << child
        when 'bad_fit'
          school_stats[:exit_reason_parent_bad_fit] << child
        when 'equity'
          school_stats[:exit_reason_parent_equity] << child
        when 'family_dissatisfied'
          school_stats[:exit_reason_parent_family_dissatisfied] << child
        when 'natural_disaster'
          school_stats[:exit_reason_parent_natural_disaster] << child
        when 'entered_public_system'
          school_stats[:exit_reason_parent_entered_public_system] << child
        when 'transferred_multi_year'
          school_stats[:exit_reason_parent_transferred_multi_year] << child
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
    "#{PREVIOUS_YEAR} Total Children - GOM",
    "#{PREVIOUS_YEAR} Total Children - White",
    "#{PREVIOUS_YEAR} Total Children - Low Income",
    "#{PREVIOUS_YEAR} Total Children - Medium Income",
    "#{PREVIOUS_YEAR} Total Children - High Income",
    "#{CURRENT_YEAR} Total Children",
    "#{CURRENT_YEAR} Total Children - GOM",
    "#{CURRENT_YEAR} Total Children - White",
    "#{CURRENT_YEAR} Total Children - Low Income",
    "#{CURRENT_YEAR} Total Children - Medium Income",
    "#{CURRENT_YEAR} Total Children - High Income",
    'Graduated from School',
    'Graduated from School - GOM',
    'Graduated from School - White',
    'Graduated from School - Low Income',
    'Graduated from School - Medium Income',
    'Graduated from School - High Income',
    'Graduated from School and Continued in Network',
    'Graduated from School and Continued in Network - GOM',
    'Graduated from School and Continued in Network - White',
    'Graduated from School and Continued in Network - Low Income',
    'Graduated from School and Continued in Network - Medium Income',
    'Graduated from School and Continued in Network - High Income',
    'Continued',
    'Continued - GOM',
    'Continued - White',
    'Continued - Low Income',
    'Continued - Medium Income',
    'Continued - High Income',
    'Continued at School',
    'Continued at School - GOM',
    'Continued at School - White',
    'Continued at School - Low Income',
    'Continued at School - Medium Income',
    'Continued at School - High Income',
    'Continued in Network',
    'Continued in Network - GOM',
    'Continued in Network - White',
    'Continued in Network - Low Income',
    'Continued in Network - Medium Income',
    'Continued in Network - High Income',
    'Continued at School (Kindergarten Eligible)',
    'Continued in Network (Kindergarten Eligible)',
    'Continued at School (Infant/Toddler Classroom)',
    'Continued in Network (Infant/Toddler Classroom)',
    'Continued at School (Kindergarten & Infant/Toddler Classroom)',
    'Continued in Network (Kindergarten & Infant/Toddler Classroom)',
    'Dropped School',
    'Dropped School - GOM',
    'Dropped School - White',
    'Dropped School - Low Income',
    'Dropped School - Medium Income',
    'Dropped School - High Income',
    'Dropped School but Continued in Network',
    'Dropped School but Continued in Network - GOM',
    'Dropped School but Continued in Network - White',
    'Dropped School but Continued in Network - Low Income',
    'Dropped School but Continued in Network - Medium Income',
    'Dropped School but Continued in Network - High Income',
    'Dropped School (Kindergarten Eligible)',
    'Dropped School but Continued in Network (Kindergarten Eligible)',
    'Dropped School (Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Infant/Toddler Classroom)',
    'Dropped School (Kindergarten & Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Kindergarten & Infant/Toddler Classroom)',
    'Exit: Graduated (teacher)',
    'Exit: Relocated (teacher)',
    'Exit: Expense (teacher)',
    'Exit: Hours offered (teacher)',
    'Exit: Location (teacher)',
    'Exit: Eligible for kindergarten (teacher)',
    'Exit: Asked to leave (teacher)',
    'Exit: Joined sibling (teacher)',
    'Exit: No lottery spot (teacher)',
    'Exit: Bad fit (teacher)',
    'Exit: Equity (teacher)',
    'Exit: Family dissatisfied (teacher)',
    'Exit: Natural disaster (teacher)',
    'Exit: Entered public system (teacher)',
    'Exit: Transferred multi year (teacher)',
    'Exit: Graduated (parent)',
    'Exit: Relocated (parent)',
    'Exit: Expense (parent)',
    'Exit: Hours offered (parent)',
    'Exit: Location (parent)',
    'Exit: Eligible for kindergarten (parent)',
    'Exit: Asked to leave (parent)',
    'Exit: Joined sibling (parent)',
    'Exit: No lottery spot (parent)',
    'Exit: Bad fit (parent)',
    'Exit: Equity (parent)',
    'Exit: Family dissatisfied (parent)',
    'Exit: Natural disaster (parent)',
    'Exit: Entered public system (parent)',
    'Exit: Transferred multi year (parent)',
    'Retention Rate',
    'Retention Rate - GOM',
    'Retention Rate - White',
    'Retention Rate - Low Income',
    'Retention Rate - Medium Income',
    'Retention Rate - High Income',
    'Retention Rate (Ignoring Kindergarten Eligible)',
    'Retention Rate (Ignoring Infant/Toddler Classroom)',
    'Retention Rate (Ignoring Kindergarten Eligible & Infant/Toddler Classroom)',
    'Notes',
  ]
  stats.each do |school_id, school_stats|
    school = schools.find{ |s| s['id'] == school_id }
    tp, tc = school_stats[:enrolled_previous_year].length, school_stats[:enrolled_current_year].length

    tp_gom = school_stats[:enrolled_previous_year_gom].length
    tp_white = school_stats[:enrolled_previous_year_white].length
    tp_low_income = school_stats[:enrolled_previous_year_low_income].length
    tp_medium_income = school_stats[:enrolled_previous_year_medium_income].length
    tp_high_income = school_stats[:enrolled_previous_year_high_income].length

    tc_gom = school_stats[:enrolled_current_year_gom].length
    tc_white = school_stats[:enrolled_current_year_white].length
    tc_low_income = school_stats[:enrolled_current_year_low_income].length
    tc_medium_income = school_stats[:enrolled_current_year_medium_income].length
    tc_high_income = school_stats[:enrolled_current_year_high_income].length

    gs, gsc = school_stats[:graduated_school].length, school_stats[:graduated_school_and_continued_in_network].length

    gs_gom = school_stats[:graduated_school_gom].length
    gs_white = school_stats[:graduated_school_white].length
    gs_low_income = school_stats[:graduated_school_low_income].length
    gs_medium_income = school_stats[:graduated_school_medium_income].length
    gs_high_income = school_stats[:graduated_school_high_income].length

    gsc_gom = school_stats[:graduated_school_and_continued_in_network_gom].length
    gsc_white = school_stats[:graduated_school_and_continued_in_network_white].length
    gsc_low_income = school_stats[:graduated_school_and_continued_in_network_low_income].length
    gsc_medium_income = school_stats[:graduated_school_and_continued_in_network_medium_income].length
    gsc_high_income = school_stats[:graduated_school_and_continued_in_network_high_income].length

    c = school_stats[:continued].length

    c_gom = school_stats[:continued_gom].length
    c_white = school_stats[:continued_white].length
    c_low_income = school_stats[:continued_low_income].length
    c_medium_income = school_stats[:continued_medium_income].length
    c_high_income = school_stats[:continued_high_income].length

    cs, cn = school_stats[:continued_at_school].length, school_stats[:continued_in_network].length

    cs_gom = school_stats[:continued_at_school_gom].length
    cs_white = school_stats[:continued_at_school_white].length
    cs_low_income = school_stats[:continued_at_school_low_income].length
    cs_medium_income = school_stats[:continued_at_school_medium_income].length
    cs_high_income = school_stats[:continued_at_school_high_income].length

    cn_gom = school_stats[:continued_in_network_gom].length
    cn_white = school_stats[:continued_in_network_white].length
    cn_low_income = school_stats[:continued_in_network_low_income].length
    cn_medium_income = school_stats[:continued_in_network_medium_income].length
    cn_high_income = school_stats[:continued_in_network_high_income].length

    csk, cnk = school_stats[:continued_at_school_kindergarten].length, school_stats[:continued_in_network_kindergarten].length
    csit, cnit = school_stats[:continued_at_school_infant_toddler].length, school_stats[:continued_in_network_infant_toddler].length
    cskit, cnkit = school_stats[:continued_at_school_kindergarten_or_infant_toddler].length, school_stats[:continued_in_network_kindergarten_or_infant_toddler].length
    ds, dscn = school_stats[:dropped_school].length, school_stats[:dropped_school_but_continued_in_network].length

    ds_gom = school_stats[:dropped_school_gom].length
    ds_white = school_stats[:dropped_school_white].length
    ds_low_income = school_stats[:dropped_school_low_income].length
    ds_medium_income = school_stats[:dropped_school_medium_income].length
    ds_high_income = school_stats[:dropped_school_high_income].length

    dscn_gom = school_stats[:dropped_school_but_continued_in_network_gom].length
    dscn_white = school_stats[:dropped_school_but_continued_in_network_white].length
    dscn_low_income = school_stats[:dropped_school_but_continued_in_network_low_income].length
    dscn_medium_income = school_stats[:dropped_school_but_continued_in_network_medium_income].length
    dscn_high_income = school_stats[:dropped_school_but_continued_in_network_high_income].length

    dsk, dscnk = school_stats[:dropped_school_kindergarten].length, school_stats[:dropped_school_but_continued_in_network_kindergarten].length
    dsit, dscnit = school_stats[:dropped_school_infant_toddler].length, school_stats[:dropped_school_but_continued_in_network_infant_toddler].length
    dskit, dscnkit = school_stats[:dropped_school_kindergarten_or_infant_toddler].length, school_stats[:dropped_school_but_continued_in_network_kindergarten_or_infant_toddler].length
    row = [
      school['name'],
      tp,
      tp_gom,
      tp_white,
      tp_low_income,
      tp_medium_income,
      tp_high_income,
      tc,
      tc_gom,
      tc_white,
      tc_low_income,
      tc_medium_income,
      tc_high_income,
      gs,
      gs_gom,
      gs_white,
      gs_low_income,
      gs_medium_income,
      gs_high_income,
      gsc,
      gsc_gom,
      gsc_white,
      gsc_low_income,
      gsc_medium_income,
      gsc_high_income,
      c,
      c_gom,
      c_white,
      c_low_income,
      c_medium_income,
      c_high_income,
      cs,
      cs_gom,
      cs_white,
      cs_low_income,
      cs_medium_income,
      cs_high_income,
      cn,
      cn_gom,
      cn_white,
      cn_low_income,
      cn_medium_income,
      cn_high_income,
      csk,
      cnk,
      csit,
      cnit,
      cskit,
      cnkit,
      ds,
      ds_gom,
      ds_white,
      ds_low_income,
      ds_medium_income,
      ds_high_income,
      dscn,
      dscn_gom,
      dscn_white,
      dscn_low_income,
      dscn_medium_income,
      dscn_high_income,
      dsk,
      dscnk,
      dsit,
      dscnit,
      dskit,
      dscnkit,
      school_stats[:exit_reason_teacher_graduated].length,
      school_stats[:exit_reason_teacher_relocated].length,
      school_stats[:exit_reason_teacher_expense].length,
      school_stats[:exit_reason_teacher_hours_offered].length,
      school_stats[:exit_reason_teacher_location].length,
      school_stats[:exit_reason_teacher_eligible_for_kindergarten].length,
      school_stats[:exit_reason_teacher_asked_to_leave].length,
      school_stats[:exit_reason_teacher_joined_sibling].length,
      school_stats[:exit_reason_teacher_no_lottery_spot].length,
      school_stats[:exit_reason_teacher_bad_fit].length,
      school_stats[:exit_reason_teacher_equity].length,
      school_stats[:exit_reason_teacher_family_dissatisfied].length,
      school_stats[:exit_reason_teacher_natural_disaster].length,
      school_stats[:exit_reason_teacher_entered_public_system].length,
      school_stats[:exit_reason_teacher_transferred_multi_year].length,
      school_stats[:exit_reason_parent_graduated].length,
      school_stats[:exit_reason_parent_relocated].length,
      school_stats[:exit_reason_parent_expense].length,
      school_stats[:exit_reason_parent_hours_offered].length,
      school_stats[:exit_reason_parent_location].length,
      school_stats[:exit_reason_parent_eligible_for_kindergarten].length,
      school_stats[:exit_reason_parent_asked_to_leave].length,
      school_stats[:exit_reason_parent_joined_sibling].length,
      school_stats[:exit_reason_parent_no_lottery_spot].length,
      school_stats[:exit_reason_parent_bad_fit].length,
      school_stats[:exit_reason_parent_equity].length,
      school_stats[:exit_reason_parent_family_dissatisfied].length,
      school_stats[:exit_reason_parent_natural_disaster].length,
      school_stats[:exit_reason_parent_entered_public_system].length,
      school_stats[:exit_reason_parent_transferred_multi_year].length
    ]

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
      row.concat(Array.new(9, nil))
      puts "#{school['name']} not enough session/children data: #{notes.join(', ')}"
    elsif (cs + ds) > 0 # Computing retention rate at school specifically, i.e. not considering when child continues in network
      rate = ((cs * 100.0) / (cs + ds)).round
      row << "#{rate}%"
      puts "#{school['name']} => #{rate}% #{notes.join(', ')}"

      # Retention rate GOM
      if (cs_gom + ds_gom) > 0
        rate = ((cs_gom * 100.0) / (cs_gom + ds_gom)).round
        row << "#{rate}%"
      else
        row << nil
      end

      # Retention rate White
      if (cs_white + ds_white) > 0
        rate = ((cs_white * 100.0) / (cs_white + ds_white)).round
        row << "#{rate}%"
      else
        row << nil
      end

      # Retention rate Low Income
      if (cs_low_income + ds_low_income) > 0
        rate = ((cs_low_income * 100.0) / (cs_low_income + ds_low_income)).round
        row << "#{rate}%"
      else
        row << nil
      end

      # Retention rate Medium Income
      if (cs_medium_income + ds_medium_income) > 0
        rate = ((cs_medium_income * 100.0) / (cs_medium_income + ds_medium_income)).round
        row << "#{rate}%"
      else
        row << nil
      end

      # Retention rate High Income
      if (cs_high_income + ds_high_income) > 0
        rate = ((cs_high_income * 100.0) / (cs_high_income + ds_high_income)).round
        row << "#{rate}%"
      else
        row << nil
      end

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
      row.concat(Array.new(9, "100%"))
    else
      row.concat(Array.new(9, nil))
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
    "#{PREVIOUS_YEAR} Total Children - GOM",
    "#{PREVIOUS_YEAR} Total Children - White",
    "#{PREVIOUS_YEAR} Total Children - Low Income",
    "#{PREVIOUS_YEAR} Total Children - Medium Income",
    "#{PREVIOUS_YEAR} Total Children - High Income",
    "#{CURRENT_YEAR} Total Children",
    "#{CURRENT_YEAR} Total Children - GOM",
    "#{CURRENT_YEAR} Total Children - White",
    "#{CURRENT_YEAR} Total Children - Low Income",
    "#{CURRENT_YEAR} Total Children - Medium Income",
    "#{CURRENT_YEAR} Total Children - High Income",
    'Graduated from School',
    'Graduated from School - GOM',
    'Graduated from School - White',
    'Graduated from School - Low Income',
    'Graduated from School - Medium Income',
    'Graduated from School - High Income',
    'Graduated from School and Continued in Network',
    'Graduated from School and Continued in Network - GOM',
    'Graduated from School and Continued in Network - White',
    'Graduated from School and Continued in Network - Low Income',
    'Graduated from School and Continued in Network - Medium Income',
    'Graduated from School and Continued in Network - High Income',
    'Continued',
    'Continued - GOM',
    'Continued - White',
    'Continued - Low Income',
    'Continued - Medium Income',
    'Continued - High Income',
    'Continued at School',
    'Continued at School - GOM',
    'Continued at School - White',
    'Continued at School - Low Income',
    'Continued at School - Medium Income',
    'Continued at School - High Income',
    'Continued in Network',
    'Continued in Network - GOM',
    'Continued in Network - White',
    'Continued in Network - Low Income',
    'Continued in Network - Medium Income',
    'Continued in Network - High Income',
    'Continued at School (Kindergarten Eligible)',
    'Continued in Network (Kindergarten Eligible)',
    'Continued at School (Infant/Toddler Eligible)',
    'Continued in Network (Infant/Toddler Eligible)',
    'Continued at School (Kindergarten or Infant/Toddler Eligible)',
    'Continued in Network (Kindergarten or Infant/Toddler Eligible)',
    'Dropped School',
    'Dropped School - GOM',
    'Dropped School - White',
    'Dropped School - Low Income',
    'Dropped School - Medium Income',
    'Dropped School - High Income',
    'Dropped School but Continued in Network',
    'Dropped School but Continued in Network - GOM',
    'Dropped School but Continued in Network - White',
    'Dropped School but Continued in Network - Low Income',
    'Dropped School but Continued in Network - Medium Income',
    'Dropped School but Continued in Network - High Income',
    'Dropped School (Kindergarten Eligible)',
    'Dropped School but Continued in Network (Kindergarten Eligible)',
    'Dropped School (Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Infant/Toddler Classrooms)',
    'Dropped School (Kindergarten or Infant/Toddler Classroom)',
    'Dropped School but Continued in Network (Kindergarten or Infant/Toddler Classrooms)',
    'Exit: Graduated (teacher)',
    'Exit: Relocated (teacher)',
    'Exit: Expense (teacher)',
    'Exit: Hours offered (teacher)',
    'Exit: Location (teacher)',
    'Exit: Eligible for kindergarten (teacher)',
    'Exit: Asked to leave (teacher)',
    'Exit: Joined sibling (teacher)',
    'Exit: No lottery spot (teacher)',
    'Exit: Bad fit (teacher)',
    'Exit: Equity (teacher)',
    'Exit: Family dissatisfied (teacher)',
    'Exit: Natural disaster (teacher)',
    'Exit: Entered public system (teacher)',
    'Exit: Transferred multi year (teacher)',
    'Exit: Graduated (parent)',
    'Exit: Relocated (parent)',
    'Exit: Expense (parent)',
    'Exit: Hours offered (parent)',
    'Exit: Location (parent)',
    'Exit: Eligible for kindergarten (parent)',
    'Exit: Asked to leave (parent)',
    'Exit: Joined sibling (parent)',
    'Exit: No lottery spot (parent)',
    'Exit: Bad fit (parent)',
    'Exit: Equity (parent)',
    'Exit: Family dissatisfied (parent)',
    'Exit: Natural disaster (parent)',
    'Exit: Entered public system (parent)',
    'Exit: Transferred multi year (parent)',
    'Retention Rate (schools)',
    'Retention Rate GOM (schools)',
    'Retention Rate White (schools)',
    'Retention Rate Low Income (schools)',
    'Retention Rate Medium Income (schools)',
    'Retention Rate High Income (schools)',
    'Retention Rate (schools: Ignoring Kindergarten Eligible)',
    'Retention Rate (schools: Ignoring Toddler/Infant Classrooms)',
    'Retention Rate (schools: Ignoring Kindergarten and Toddler/Infant Classrooms)',
    'Retention Rate (network)',
    'Retention Rate GOM (network)',
    'Retention Rate White (network)',
    'Retention Rate Low Income (network)',
    'Retention Rate Medium Income (network)',
    'Retention Rate High income (network)',
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

    group_stats = {tp:0, tp_gom: 0, tp_white: 0, tp_low_income: 0, tp_medium_income: 0, tp_high_income: 0, tc: 0, tc_gom: 0, tc_white: 0, tc_low_income: 0, tc_medium_income: 0, tc_high_income: 0, gs: 0, gs_gom: 0, gs_white: 0, gs_low_income: 0, gs_medium_income: 0, gs_high_income: 0, gsc: 0, gsc_gom: 0, gsc_white: 0, gsc_low_income: 0, gsc_medium_income: 0, gsc_high_income: 0, c: 0, c_gom: 0, c_white: 0, c_low_income: 0, c_medium_income: 0, c_high_income: 0, cs: 0, cs_gom: 0, cs_white: 0, cs_low_income: 0, cs_medium_income: 0, cs_high_income: 0, cn: 0, cn_gom: 0, cn_white: 0, cn_low_income: 0, cn_medium_income: 0, cn_high_income: 0, csk: 0, cnk: 0, csit: 0, cnit: 0, cskit: 0, cnkit: 0, ds:0, ds_gom: 0, ds_white: 0, ds_low_income: 0, ds_medium_income: 0, ds_high_income: 0, dscn: 0, dscn_gom: 0, dscn_white: 0, dscn_low_income: 0, dscn_medium_income: 0, dscn_high_income: 0, dsk: 0, dscnk: 0, dsit: 0, dscnit: 0, dskit: 0, dscnkit: 0, exit_reason_teacher_graduated: 0, exit_reason_teacher_relocated: 0, exit_reason_teacher_expense: 0, exit_reason_teacher_hours_offered: 0, exit_reason_teacher_location: 0, exit_reason_teacher_eligible_for_kindergarten: 0, exit_reason_teacher_asked_to_leave: 0, exit_reason_teacher_joined_sibling: 0, exit_reason_teacher_no_lottery_spot: 0, exit_reason_teacher_bad_fit: 0, exit_reason_teacher_equity: 0, exit_reason_teacher_family_dissatisfied: 0, exit_reason_teacher_natural_disaster: 0, exit_reason_teacher_entered_public_system: 0, exit_reason_teacher_transferred_multi_year: 0, exit_reason_parent_graduated: 0, exit_reason_parent_relocated: 0, exit_reason_parent_expense: 0, exit_reason_parent_hours_offered: 0, exit_reason_parent_location: 0, exit_reason_parent_eligible_for_kindergarten: 0, exit_reason_parent_asked_to_leave: 0, exit_reason_parent_joined_sibling: 0, exit_reason_parent_no_lottery_spot: 0, exit_reason_parent_bad_fit: 0, exit_reason_parent_equity: 0, exit_reason_parent_family_dissatisfied: 0, exit_reason_parent_natural_disaster: 0, exit_reason_parent_entered_public_system: 0, exit_reason_parent_transferred_multi_year: 0}
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
      group_stats[:tp_gom] += school_stats[:enrolled_previous_year_gom].length
      group_stats[:tp_white] += school_stats[:enrolled_previous_year_white].length
      group_stats[:tp_low_income] += school_stats[:enrolled_previous_year_low_income].length
      group_stats[:tp_medium_income] += school_stats[:enrolled_previous_year_medium_income].length
      group_stats[:tp_high_income] += school_stats[:enrolled_previous_year_high_income].length
      group_stats[:tc] += school_stats[:enrolled_current_year].length
      group_stats[:tc_gom] += school_stats[:enrolled_current_year_gom].length
      group_stats[:tc_white] += school_stats[:enrolled_current_year_white].length
      group_stats[:tc_low_income] += school_stats[:enrolled_current_year_low_income].length
      group_stats[:tc_medium_income] += school_stats[:enrolled_current_year_medium_income].length
      group_stats[:tc_high_income] += school_stats[:enrolled_current_year_high_income].length
      group_stats[:gs] += school_stats[:graduated_school].length
      group_stats[:gs_gom] += school_stats[:graduated_school_gom].length
      group_stats[:gs_white] += school_stats[:graduated_school_white].length
      group_stats[:gs_low_income] += school_stats[:graduated_school_low_income].length
      group_stats[:gs_medium_income] += school_stats[:graduated_school_medium_income].length
      group_stats[:gs_high_income] += school_stats[:graduated_school_high_income].length
      group_stats[:gsc] += school_stats[:graduated_school_and_continued_in_network].length
      group_stats[:gsc_gom] += school_stats[:graduated_school_and_continued_in_network_gom].length
      group_stats[:gsc_white] += school_stats[:graduated_school_and_continued_in_network_white].length
      group_stats[:gsc_low_income] += school_stats[:graduated_school_and_continued_in_network_low_income].length
      group_stats[:gsc_medium_income] += school_stats[:graduated_school_and_continued_in_network_medium_income].length
      group_stats[:gsc_high_income] += school_stats[:graduated_school_and_continued_in_network_high_income].length
      group_stats[:c] += school_stats[:continued].length
      group_stats[:c_gom] += school_stats[:continued_gom].length
      group_stats[:c_white] += school_stats[:continued_white].length
      group_stats[:c_low_income] += school_stats[:continued_low_income].length
      group_stats[:c_medium_income] += school_stats[:continued_medium_income].length
      group_stats[:c_high_income] += school_stats[:continued_high_income].length
      group_stats[:cs] += school_stats[:continued_at_school].length
      group_stats[:cs_gom] += school_stats[:continued_at_school_gom].length
      group_stats[:cs_white] += school_stats[:continued_at_school_white].length
      group_stats[:cs_low_income] += school_stats[:continued_at_school_low_income].length
      group_stats[:cs_medium_income] += school_stats[:continued_at_school_medium_income].length
      group_stats[:cs_high_income] += school_stats[:continued_at_school_high_income].length
      group_stats[:cn] += school_stats[:continued_in_network].length
      group_stats[:cn_gom] += school_stats[:continued_in_network_gom].length
      group_stats[:cn_white] += school_stats[:continued_in_network_white].length
      group_stats[:cn_low_income] += school_stats[:continued_in_network_low_income].length
      group_stats[:cn_medium_income] += school_stats[:continued_in_network_medium_income].length
      group_stats[:cn_high_income] += school_stats[:continued_in_network_high_income].length
      group_stats[:csk] += school_stats[:continued_at_school_kindergarten].length
      group_stats[:cnk] += school_stats[:continued_in_network_kindergarten].length
      group_stats[:csit] += school_stats[:continued_at_school_infant_toddler].length
      group_stats[:cnit] += school_stats[:continued_in_network_infant_toddler].length
      group_stats[:cskit] += school_stats[:continued_at_school_kindergarten_or_infant_toddler].length
      group_stats[:cnkit] += school_stats[:continued_in_network_kindergarten_or_infant_toddler].length
      group_stats[:ds] += school_stats[:dropped_school].length
      group_stats[:ds_gom] += school_stats[:dropped_school_gom].length
      group_stats[:ds_white] += school_stats[:dropped_school_white].length
      group_stats[:ds_low_income] += school_stats[:dropped_school_low_income].length
      group_stats[:ds_medium_income] += school_stats[:dropped_school_medium_income].length
      group_stats[:ds_high_income] += school_stats[:dropped_school_high_income].length
      group_stats[:dscn] += school_stats[:dropped_school_but_continued_in_network].length
      group_stats[:dscn_gom] += school_stats[:dropped_school_but_continued_in_network_gom].length
      group_stats[:dscn_white] += school_stats[:dropped_school_but_continued_in_network_white].length
      group_stats[:dscn_low_income] += school_stats[:dropped_school_but_continued_in_network_low_income].length
      group_stats[:dscn_medium_income] += school_stats[:dropped_school_but_continued_in_network_medium_income].length
      group_stats[:dscn_high_income] += school_stats[:dropped_school_but_continued_in_network_high_income].length
      group_stats[:dsk] += school_stats[:dropped_school_kindergarten].length
      group_stats[:dscnk] += school_stats[:dropped_school_but_continued_in_network_kindergarten].length
      group_stats[:dsit] += school_stats[:dropped_school_infant_toddler].length
      group_stats[:dscnit] += school_stats[:dropped_school_but_continued_in_network_infant_toddler].length
      group_stats[:dskit] += school_stats[:dropped_school_kindergarten_or_infant_toddler].length
      group_stats[:dscnkit] += school_stats[:dropped_school_but_continued_in_network_kindergarten_or_infant_toddler].length
      group_stats[:exit_reason_teacher_graduated] += school_stats[:exit_reason_teacher_graduated].length
      group_stats[:exit_reason_teacher_relocated] += school_stats[:exit_reason_teacher_relocated].length
      group_stats[:exit_reason_teacher_expense] += school_stats[:exit_reason_teacher_expense].length
      group_stats[:exit_reason_teacher_hours_offered] += school_stats[:exit_reason_teacher_hours_offered].length
      group_stats[:exit_reason_teacher_location] += school_stats[:exit_reason_teacher_location].length
      group_stats[:exit_reason_teacher_eligible_for_kindergarten] += school_stats[:exit_reason_teacher_eligible_for_kindergarten].length
      group_stats[:exit_reason_teacher_asked_to_leave] += school_stats[:exit_reason_teacher_asked_to_leave].length
      group_stats[:exit_reason_teacher_joined_sibling] += school_stats[:exit_reason_teacher_joined_sibling].length
      group_stats[:exit_reason_teacher_no_lottery_spot] += school_stats[:exit_reason_teacher_no_lottery_spot].length
      group_stats[:exit_reason_teacher_bad_fit] += school_stats[:exit_reason_teacher_bad_fit].length
      group_stats[:exit_reason_teacher_equity] += school_stats[:exit_reason_teacher_equity].length
      group_stats[:exit_reason_teacher_family_dissatisfied] += school_stats[:exit_reason_teacher_family_dissatisfied].length
      group_stats[:exit_reason_teacher_natural_disaster] += school_stats[:exit_reason_teacher_natural_disaster].length
      group_stats[:exit_reason_teacher_entered_public_system] += school_stats[:exit_reason_teacher_entered_public_system].length
      group_stats[:exit_reason_teacher_transferred_multi_year] += school_stats[:exit_reason_teacher_transferred_multi_year].length
      group_stats[:exit_reason_parent_graduated] += school_stats[:exit_reason_parent_graduated].length
      group_stats[:exit_reason_parent_relocated] += school_stats[:exit_reason_parent_relocated].length
      group_stats[:exit_reason_parent_expense] += school_stats[:exit_reason_parent_expense].length
      group_stats[:exit_reason_parent_hours_offered] += school_stats[:exit_reason_parent_hours_offered].length
      group_stats[:exit_reason_parent_location] += school_stats[:exit_reason_parent_location].length
      group_stats[:exit_reason_parent_eligible_for_kindergarten] += school_stats[:exit_reason_parent_eligible_for_kindergarten].length
      group_stats[:exit_reason_parent_asked_to_leave] += school_stats[:exit_reason_parent_asked_to_leave].length
      group_stats[:exit_reason_parent_joined_sibling] += school_stats[:exit_reason_parent_joined_sibling].length
      group_stats[:exit_reason_parent_no_lottery_spot] += school_stats[:exit_reason_parent_no_lottery_spot].length
      group_stats[:exit_reason_parent_bad_fit] += school_stats[:exit_reason_parent_bad_fit].length
      group_stats[:exit_reason_parent_equity] += school_stats[:exit_reason_parent_equity].length
      group_stats[:exit_reason_parent_family_dissatisfied] += school_stats[:exit_reason_parent_family_dissatisfied].length
      group_stats[:exit_reason_parent_natural_disaster] += school_stats[:exit_reason_parent_natural_disaster].length
      group_stats[:exit_reason_parent_entered_public_system] += school_stats[:exit_reason_parent_entered_public_system].length
      group_stats[:exit_reason_parent_transferred_multi_year] += school_stats[:exit_reason_parent_transferred_multi_year].length
    end

    row = [
      gs_config['name'],
      gs_config['type'],
      group_schools.count,
      group_stats[:tp],
      group_stats[:tp_gom],
      group_stats[:tp_white],
      group_stats[:tp_low_income],
      group_stats[:tp_medium_income],
      group_stats[:tp_high_income],
      group_stats[:tc],
      group_stats[:tc_gom],
      group_stats[:tc_white],
      group_stats[:tc_low_income],
      group_stats[:tc_medium_income],
      group_stats[:tc_high_income],
      group_stats[:gs],
      group_stats[:gs_gom],
      group_stats[:gs_white],
      group_stats[:gs_low_income],
      group_stats[:gs_medium_income],
      group_stats[:gs_high_income],
      group_stats[:gsc],
      group_stats[:gsc_gom],
      group_stats[:gsc_white],
      group_stats[:gsc_low_income],
      group_stats[:gsc_medium_income],
      group_stats[:gsc_high_income],
      group_stats[:c],
      group_stats[:c_gom],
      group_stats[:c_white],
      group_stats[:c_low_income],
      group_stats[:c_medium_income],
      group_stats[:c_high_income],
      group_stats[:cs],
      group_stats[:cs_gom],
      group_stats[:cs_white],
      group_stats[:cs_low_income],
      group_stats[:cs_medium_income],
      group_stats[:cs_high_income],
      group_stats[:cn],
      group_stats[:cn_gom],
      group_stats[:cn_white],
      group_stats[:cn_low_income],
      group_stats[:cn_medium_income],
      group_stats[:cn_high_income],
      group_stats[:csk],
      group_stats[:cnk],
      group_stats[:csit],
      group_stats[:cnit],
      group_stats[:cskit],
      group_stats[:cnkit],
      group_stats[:ds],
      group_stats[:ds_gom],
      group_stats[:ds_white],
      group_stats[:ds_low_income],
      group_stats[:ds_medium_income],
      group_stats[:ds_high_income],
      group_stats[:dscn],
      group_stats[:dscn_gom],
      group_stats[:dscn_white],
      group_stats[:dscn_low_income],
      group_stats[:dscn_medium_income],
      group_stats[:dscn_high_income],
      group_stats[:dsk],
      group_stats[:dscnk],
      group_stats[:dsit],
      group_stats[:dscnit],
      group_stats[:dskit],
      group_stats[:dscnkit],
      group_stats[:exit_reason_teacher_graduated],
      group_stats[:exit_reason_teacher_relocated],
      group_stats[:exit_reason_teacher_expense],
      group_stats[:exit_reason_teacher_hours_offered],
      group_stats[:exit_reason_teacher_location],
      group_stats[:exit_reason_teacher_eligible_for_kindergarten],
      group_stats[:exit_reason_teacher_asked_to_leave],
      group_stats[:exit_reason_teacher_joined_sibling],
      group_stats[:exit_reason_teacher_no_lottery_spot],
      group_stats[:exit_reason_teacher_bad_fit],
      group_stats[:exit_reason_teacher_equity],
      group_stats[:exit_reason_teacher_family_dissatisfied],
      group_stats[:exit_reason_teacher_natural_disaster],
      group_stats[:exit_reason_teacher_entered_public_system],
      group_stats[:exit_reason_teacher_transferred_multi_year],
      group_stats[:exit_reason_parent_graduated],
      group_stats[:exit_reason_parent_relocated],
      group_stats[:exit_reason_parent_expense],
      group_stats[:exit_reason_parent_hours_offered],
      group_stats[:exit_reason_parent_location],
      group_stats[:exit_reason_parent_eligible_for_kindergarten],
      group_stats[:exit_reason_parent_asked_to_leave],
      group_stats[:exit_reason_parent_joined_sibling],
      group_stats[:exit_reason_parent_no_lottery_spot],
      group_stats[:exit_reason_parent_bad_fit],
      group_stats[:exit_reason_parent_equity],
      group_stats[:exit_reason_parent_family_dissatisfied],
      group_stats[:exit_reason_parent_natural_disaster],
      group_stats[:exit_reason_parent_entered_public_system],
      group_stats[:exit_reason_parent_transferred_multi_year]]

    # School retention
    if (group_stats[:cs] + group_stats[:ds]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs] * 100.0 / (group_stats[:cs] + group_stats[:ds])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) not enough statistical data"
    end

    # School retention GOM
    if (group_stats[:cs_gom] + group_stats[:ds_gom]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs_gom] * 100.0 / (group_stats[:cs_gom] + group_stats[:ds_gom])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} GOM (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} GOM (#{gs_config['type']}) not enough statistical data"
    end

    # School retention White
    if (group_stats[:cs_white] + group_stats[:ds_white]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs_white] * 100.0 / (group_stats[:cs_white] + group_stats[:ds_white])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} White (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} White (#{gs_config['type']}) not enough statistical data"
    end

    # School retention Low Income
    if (group_stats[:cs_low_income] + group_stats[:ds_low_income]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs_low_income] * 100.0 / (group_stats[:cs_low_income] + group_stats[:ds_low_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} Low Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} Low Income (#{gs_config['type']}) not enough statistical data"
    end

    # School retention Medium Income
    if (group_stats[:cs_medium_income] + group_stats[:ds_medium_income]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs_medium_income] * 100.0 / (group_stats[:cs_medium_income] + group_stats[:ds_medium_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} Medium Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} Medium Income (#{gs_config['type']}) not enough statistical data"
    end

    # School retention High Income
    if (group_stats[:cs_high_income] + group_stats[:ds_high_income]) > 0 # computing avg. school retention rate (not considering retention within network)
      rate = (group_stats[:cs_high_income] * 100.0 / (group_stats[:cs_high_income] + group_stats[:ds_high_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} High Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} High Income (#{gs_config['type']}) not enough statistical data"
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
    else
      row << nil
      puts "#{gs_config['name']} (#{gs_config['type']}) not enough statistical data"
    end

    # Network retention GOM
    if (group_stats[:c_gom] + group_stats[:ds_gom] - group_stats[:dscn_gom]) > 0
      rate = (group_stats[:c_gom] * 100.0 / (group_stats[:c_gom] + group_stats[:ds_gom] - group_stats[:dscn_gom])).round
      row << "#{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} GOM (#{gs_config['type']}) not enough statistical data"
    end

    # Network retention White
    if (group_stats[:c_white] + group_stats[:ds_white] - group_stats[:dscn_white]) > 0
      rate = (group_stats[:c_white] * 100.0 / (group_stats[:c_white] + group_stats[:ds_white] - group_stats[:dscn_white])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} White (#{gs_config['type']}) not enough statistical data"
    end
    
    # School retention Low Income
    if (group_stats[:c_low_income] + group_stats[:ds_low_income] - group_stats[:dscn_low_income]) > 0
      rate = (group_stats[:c_low_income] * 100.0 / (group_stats[:c_low_income] + group_stats[:ds_low_income] - group_stats[:dscn_low_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} Low Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} Low Income (#{gs_config['type']}) not enough statistical data"
    end

    # School retention Medium Income
    if (group_stats[:c_medium_income] + group_stats[:ds_medium_income] - group_stats[:dscn_medium_income]) > 0
      rate = (group_stats[:c_medium_income] * 100.0 / (group_stats[:c_medium_income] + group_stats[:ds_medium_income] - group_stats[:dscn_medium_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} Medium Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} Medium Income (#{gs_config['type']}) not enough statistical data"
    end

    # School retention High Income
    if (group_stats[:c_high_income] + group_stats[:ds_high_income] - group_stats[:dscn_high_income]) > 0
      rate = (group_stats[:c_high_income] * 100.0 / (group_stats[:c_high_income] + group_stats[:ds_high_income] - group_stats[:dscn_high_income])).round
      row << "#{rate}%"
      puts "#{gs_config['name']} High Income (#{gs_config['type']}) => #{rate}%"
    else
      row << nil
      puts "#{gs_config['name']} High Income (#{gs_config['type']}) not enough statistical data"
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