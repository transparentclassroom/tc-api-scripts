# Thanks - https://github.com/adrianomitre/match_author_names/blob/master/match_author_names.rb

require 'damerau-levenshtein'
require 'set'

module NamesMatcher
  module_function

  def string_distance(a, b)
    DamerauLevenshtein.string_distance(a, b, 1, 1_000)
  end

  def array_distance(a, b)
    DamerauLevenshtein.array_distance(a, b, 1, 1_000)
  end

  def relative_dist(a, b, callable)
    mean_sz = [a, b].sum(&:size) / 2.0
    callable.call(a, b) / mean_sz.to_f
  end

  CASE_SENSITIVE = false
  SAME_TOKEN_THRESHOLD = 1.0/3

  def same_token?(a, b,
                  threshold: SAME_TOKEN_THRESHOLD,
                  case_sensitive: CASE_SENSITIVE
  )
    a, b = [a, b].sort_by(&:size)
    a, b = [a, b].map(&:downcase) unless case_sensitive
    if a.size == 1
      a[0] == b[0]
    else
      relative_dist(a, b, method(:string_distance)) <= threshold
    end
  end

  SAME_NAME_THRESHOLD = 0.2

  def distance(a, b)
    a, b = [a, b].map { |x| scrub_name(x)}
    a, b = [a, b].sort_by(&:size)
    aw, bw = [a, b].map { |x| split_in_names_and_initials(x) }
    abw = aw + bw
    token_indices = abw.map { |w1| abw.index { |w2| same_token?(w1, w2) } }
    a, b = [token_indices[0, aw.size], token_indices[aw.size..-1]]
    if a.to_set.subset?(b.to_set)
      SAME_NAME_THRESHOLD * 0.5
    else
      relative_dist(a, b, method(:min_rotated_array_distance))
    end
  end

  def scrub_name(name)
    name.gsub(/[^0-9A-Za-z\s]/, '').downcase
  end

  def split_in_names_and_initials(s)
    s.split(/(?:[.,]\s*)|\s+/)
  end

  def rotations(v)
    v.size.times.map { |i| v.rotate(i) }
  end

  def min_rotated_array_distance(u, v)
    rotations(u).map { |ru| array_distance(ru, v) }.min
  end

end
