require "kemal"

struct Person

  def initialize(@name, @age, @location)
    @key = SecureRandom.hex
  end

  JSON.mapping(
    name: String,
    age: Int32,
    location: String,
    key: String
  )
end

get "/" do
  File.read "index.html"
end

ws "/" do |socket|
  puts "socket connected #{socket}"
  person = [Person.new("tyler", 32, "portland"), Person.new("heather", 40, "portland")]
  socket.send person.to_json
  # socket.on_message do |message|
  #   puts Request.from_json message
  # end
end

Kemal.run