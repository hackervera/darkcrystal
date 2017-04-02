require "kemal"
require "db"
require "pg"
require "kemal-session"
require "markdown"


struct Post
  def initialize(@author_id, @body, @title, @id)
  end

  JSON.mapping(
    author_id: Int32,
    body: String,
    title: String,
    id: Int32
  )
end


struct User
  def initialize(@img, @name, @id)
  end

  JSON.mapping(
    name: String,
    img: String,
    id: Int32
  )

  include Session::StorableObject
end


get "/" do |env|
  # env.session.object("current_user", User.new("","Test user", 42))
  current_user = env.session.object?("current_user")
  DB.open ENV["DATABASE_URL"] do |db|
    db.query "select img, name, body, title, posts.id, users.id from users,posts where posts.author_id = users.id order by posts.created_at desc" do |rs|
      posts = [] of Hash(Symbol, String | Int32)
      rs.each do 
        posts << {
          :img => rs.read(String), 
          :name => rs.read(String), 
          :body => rs.read(String), 
          :title => rs.read(String), 
          :id => rs.read(Int32),
          :author_id => rs.read(Int32)
        }
      end  
      render "index.html.ecr"
    end
  end
end

get "/delete/:id" do |env|
  post_id = env.params.url["id"]
  
  current_user = env.session.object("current_user")
  DB.open ENV["DATABASE_URL"] do |db|
    db.query "select posts.id from posts,users where posts.id = $1 and posts.author_id = $2", post_id, current_user.id do |rs|
      puts "looking for post"
      rs.each do
        if post_id = rs.read(Int32|Nil)
          puts "got post id"
          db.exec "delete from posts where id = $1", post_id
        end
      end
    end
  end
  env.redirect "/"
end

post "/submit" do |env|
  current_user = env.session.object("current_user")
  markdown = Markdown.to_html(env.params.body["body"].as(String))
  DB.open ENV["DATABASE_URL"] do |db|
    db.exec "insert into posts values ($1,$2,$3)", current_user.id, markdown, env.params.body["title"]
  end
  env.redirect "/"
end

get "/login" do |env|
  code = env.params.query["code"]
  puts code.inspect
  resp = HTTP::Client.post_form("https://github.com/login/oauth/access_token", 
   
  {
    "client_id" => ENV["GITHUB_CLIENT_ID"],
    "client_secret" => ENV["GITHUB_CLIENT_SECRET"],
    "code" => code.as(String),
    "accept" => "json"
  },
   headers: HTTP::Headers{"Accept" => "application/json"}
  
  )
  puts resp.body.inspect
  access_token = JSON.parse(resp.body)["access_token"]
  resp = HTTP::Client.get("https://api.github.com/user?access_token=#{access_token}")
  puts resp.body
  user_data = JSON.parse(resp.body)
  name = user_data["name"].as_s
  id = user_data["id"].as_i
  img = user_data["avatar_url"].as_s

  env.session.object("current_user", User.new(img, name, id))
  DB.open ENV["DATABASE_URL"] do |db|
    users = [] of Int32
    db.query "select id from users where id = $1", id do |rs|
      rs.each do 
        users << rs.read(Int32)
      end  
    end
    if users.empty?
      db.exec "insert into users values ($1, $2, $3)", img, name, id
    end
  end

  env.redirect "/"
end

Session.config.secret = "sadasdjsadjljk3242342"
Kemal.run