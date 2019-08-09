require_relative './lib/transparent_classroom/client'

tc = TransparentClassroom::Client.new # base_url: 'http://localhost:3000/api/v1'
# tc.school_id = 22

children = tc.get 'children.json'

children.each do |child|
  puts child
end