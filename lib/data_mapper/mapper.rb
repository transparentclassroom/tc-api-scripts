require 'csv'
require 'json'

module Memoize
  # Thanks: Filip Defar - http://filipdefar.com/2019/03/ruby-memoization-module-from-scratch.html

  def memoize_cache
    @memoize_cache ||= {}
  end

  def memoize(method_name)
    inner_method = instance_method(method_name)
    define_singleton_method method_name do |*args|
      key = [method_name, args]
      cache = self.memoize_cache
      return cache[key] if cache.key?(key)
      cache[key] = inner_method.bind(self).call(*args)
    end
  end
end

module DataMapper
  extend Memoize

  module_function

  def parse_csv(file_path)
    fields = {}
    CSV.foreach(file_path, :headers => true, :header_converters => :symbol, :converters => :all) do |row|
      fields[row.fields[0].to_s] = Hash[row.headers[1..-1].zip(row.fields[1..-1])]
    end
    fields
  end

  def languages
    parse_csv("#{File.dirname(__FILE__)}/language.csv")
  end
  memoize :languages

  def ethnicities
    ethnicities = parse_csv("#{File.dirname(__FILE__)}/ethnicity.csv")
    ethnicities.each do |k, _|
      v = ethnicities[k][:ethnicities]
      if v.nil? or v.empty? or v == "[]"
        ethnicities[k][:ethnicities] = []
      else
        ethnicities[k][:ethnicities] = JSON.parse(v)
      end
    end
    ethnicities
  end
  memoize :ethnicities

  def income
    parse_csv("#{File.dirname(__FILE__)}/income.csv")
  end
  memoize :income

  def field_names
    parse_csv("#{File.dirname(__FILE__)}/field_names.csv")
  end
  memoize :field_names

  def languages_has_key?(key)
    key = key.strip.to_s
    self.languages.has_key?(key)
  end

  def languages_value_for(key)
    key = key.strip.to_s
    if languages_has_key?(key)
      self.languages[key][:language_category]
    else
      puts "Language unknown: #{key}, returning provided value"
      key
    end
  end

  def ethnicities_has_key?(key)
    key = key.strip.to_s
    self.ethnicities.has_key?(key)
  end

  def ethnicities_value_for(key)
    if key.kind_of?(Array)
      values = []
      key.compact.collect(&:strip).each do |k|
        k = k.strip.to_s

        if self.ethnicities.has_key?(k)
          values.append(self.ethnicities[k][:ethnicities])
        else
          puts "Race/Ethnicity unknown: #{k}, returning provided value"
          values.append(k)
        end
      end
      values.flatten.uniq
    else
      key = key.strip.to_s
      if self.ethnicities.has_key?(key)
        self.ethnicities[key][:ethnicities]
      else
        puts "Race/Ethnicity unknown: #{key}, returning provided value"
        [key]
      end
    end
  end

  def income_has_key?(key)
    key = key.strip.to_s
    self.income.has_key?(key)
  end

  def income_value_for(key)
    key = key.strip.to_s

    if income_has_key?(key)
      self.income[key][:household_income_category]
    else
      puts "Income value unknown: #{key}, returning provided value"
      key
    end
  end

  def field_names_has_key?(key)
    key = key.strip
    self.field_names.has_key?(key)
  end

  def field_names_value_for(key)
    key = key.strip

    if field_names_has_key?(key)
      self.field_names[key][:target_field_name]
    else
      puts "Field name unknown: #{key}, returning provided value"
      key
    end
  end
end
