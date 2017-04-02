require "kemal"
require "db"
require "pg"
require "kemal-session"
require "markdown"
require "oauth"

Conn = DB.open ENV["DATABASE_URL"]
TwitterClient = Twitter.new
class Twitter
  def initialize
    @client = HTTP::Client.new("api.twitter.com", tls: true)
    token = ENV["TWITTER_ACCESS_TOKEN"]
    token_secret = ENV["TWITTER_ACCESS_TOKEN_SECRET"]
    consumer = ENV["TWITTER_CONSUMER_KEY"]
    consumer_secret = ENV["TWITTER_CONSUMER_SECRET"]
    OAuth.authenticate(@client, token, token_secret, consumer, consumer_secret)
  end

  def tweet(message)
    @client.post_form("/1.1/statuses/update.json", {"status" => message})
  end
end


class Index
  @current_post : Hash(String, String | Int32) | Nil
  @posts : Array(Hash(Symbol, String | Int32))
  @current_user : User | Nil
  def initialize(@current_post, @posts, @current_user)
  end
  ECR.def_to_s "index.html.ecr"
end

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


get "/tweet/:message" do |env|
  TwitterClient.tweet(env.params.url["message"])
end

get "/" do |env|
  
  Conn.query "select img, name, body, title, posts.id, users.id from users,posts where posts.author_id = users.id order by posts.created_at desc" do |rs|
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
    Index.new(nil, posts, env.session.object?("current_user"))
  end
end

get "/signout" do |env|
  env.session.destroy
  env.redirect "/"
end

get "/edit/:id" do |env|
  post_title, post_body, post_id = Conn.query_one "select title, body, id from posts where posts.id = $1", env.params.url["id"], as: {String, String, Int32}
  posts = [] of Hash(Symbol, String | Int32)
  Conn.query "select img, name, body, title, posts.id, users.id from users,posts where posts.author_id = users.id order by posts.created_at desc" do |rs|
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
  end
  Index.new({"title" => post_title, "body" => post_body, "id" => post_id}, posts, env.session.object?("current_user"))
end

get "/updates/:id" do |env|
  current_user = env.session.object?("current_user")
  post_id = env.params.url["id"]
  posts = [] of Hash(Symbol, String | Int32)
  Conn.query "select img, name, body, title, posts.id, users.id from users,posts where posts.author_id = users.id and posts.id = $1", post_id do |rs|
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
  end
  if !posts.empty?
    Index.new(nil, posts, current_user)
  else
    env.redirect "/"
  end
end

get "/delete/:id" do |env|

  post_id = env.params.url["id"]
  
  current_user = env.session.object("current_user")
  Conn.query "select posts.id from posts,users where posts.id = $1 and posts.author_id = $2", post_id, current_user.id do |rs|
    puts "looking for post"
    rs.each do
      if post_id = rs.read(Int32|Nil)
        Conn.exec "delete from posts where id = $1", post_id
      end
    end
  end
  env.redirect "/"
end

post "/submit" do |env|
  current_user = env.session.object("current_user")
  html = Markdown.to_html(env.params.body["body"].as(String))
  title = env.params.body["title"]
  post_id = Conn.query_one "insert into posts values ($1,$2,$3) returning id", current_user.id, html, title, as: Int32
  url = "#{Kemal.config.scheme}://#{env.request.headers["host"]}/updates/#{post_id}"
  message = "#{title} #{url}"
  puts message
  puts TwitterClient.tweet(message).inspect
  env.redirect "/"
end

post "/edit/:id" do |env|
  current_user = env.session.object("current_user")
  post_id = env.params.url["id"]
  post_body = env.params.body["body"]
  post_title = env.params.body["title"]
  if post_id = Conn.query_one "select id from posts where id = $1 and posts.author_id = $2", post_id, current_user.id, as: Int32
    Conn.exec "update posts set body = $1, title = $2 where id = $3", post_body, post_title, post_id 
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
  name = user_data["login"].as_s
  id = user_data["id"].as_i
  img = user_data["avatar_url"].as_s

  env.session.object("current_user", User.new(img, name, id))
  users = [] of Int32
  Conn.query "select id from users where id = $1", id do |rs|
    rs.each do 
      users << rs.read(Int32)
    end  
  end
  if users.empty?
    Conn.exec "insert into users values ($1, $2, $3)", img, name, id
  end

  env.redirect "/"
end

Session.config.secret = ENV["DARK_SECRET"]
Kemal.run