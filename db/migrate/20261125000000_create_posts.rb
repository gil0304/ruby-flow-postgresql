# Ruby Flow デモ用の投稿テーブル。
# 適用は専用DB（DATABASE_URL で明示）でのみ行う。README 参照。
class CreatePosts < ActiveRecord::Migration[7.0]
  def change
    create_table :posts do |t|
      t.string :title, null: false, limit: 100
      t.text :body, null: false, default: ""
      t.timestamps
    end
  end
end
