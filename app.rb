require "bundler/setup"
Bundler.require

require "sinatra/reloader" if development?

require "./models.rb"

get '/' do
  @posts = Post.order(created_at: :desc).limit(50).to_a
  erb :index
end

# ---- Ruby Flow: 計測の導入とデモ用 CRUD（以下を原本に追記） ----
# 計測は 127.0.0.1 のローカル利用のみを想定。RUBY_FLOW=off で無効化できる。
RubyFlow.install(Sinatra::Application, root: __dir__)

# エラーハンドラ（404 など）を開発用の例外画面より先に使う
set :show_exceptions, :after_handler

get '/posts/new' do
  @post = Post.new
  erb :new
end

post '/posts' do
  title = params[:title].to_s
  body = params[:body].to_s
  @post = Post.new(title: title, body: body)
  saved = @post.save
  if saved
    redirect "/posts/#{@post.id}"
  else
    status 422
    erb :new
  end
end

get '/posts/:id' do
  id = params[:id].to_i
  @post = Post.find(id)
  erb :show
end

get '/posts/:id/edit' do
  id = params[:id].to_i
  @post = Post.find(id)
  erb :edit
end

post '/posts/:id' do
  id = params[:id].to_i
  @post = Post.find(id)
  title = params[:title].to_s
  body = params[:body].to_s
  saved = @post.update(title: title, body: body)
  if saved
    redirect "/posts/#{id}"
  else
    status 422
    erb :edit
  end
end

post '/posts/:id/delete' do
  id = params[:id].to_i
  post = Post.find(id)
  post.destroy
  redirect '/'
end

error ActiveRecord::RecordNotFound do
  status 404
  erb :not_found
end

not_found do
  erb :not_found
end

# DB に接続できないときは設定を変えずに案内だけ表示する（接続情報は出さない）
error ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, PG::ConnectionBad do
  status 503
  erb :db_error
end
