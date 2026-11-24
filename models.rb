require 'bundler/setup'
require 'bcrypt'
Bundler.require

ActiveRecord::Base.establish_connection

# ---- Ruby Flow デモ: 投稿モデル（以下を原本に追記） ----
require_relative 'lib/ruby_flow'
require_relative 'lib/ruby_flow/record_observer'

# 検証メッセージを日本語で表示する（初学者向け）
I18n.backend.store_translations(:ja, activerecord: { attributes: { post: { title: 'タイトル', body: '本文' } } },
                                     errors: { format: '%{attribute}%{message}',
                                               messages: { blank: 'を入力してください',
                                                           too_long: 'は%{count}文字以内で入力してください' } })
I18n.default_locale = :ja

class Post < ActiveRecord::Base
  TITLE_MAX = 100
  BODY_MAX = 1000

  # DB に確定した行 / 取り消された行を Ruby Flow に知らせる（値は許可した列のみ）
  include RubyFlow::RecordObserver

  before_validation :normalize_fields

  validates :title, presence: true, length: { maximum: TITLE_MAX }
  validates :body, length: { maximum: BODY_MAX }

  def summary
    text = body.to_s
    text.length > 40 ? "#{text[0, 40]}…" : text
  end

  private

  # 前後の空白を取り除く（データの変換）
  def normalize_fields
    self.title = title.to_s.strip
    self.body = body.to_s.strip
  end
end
