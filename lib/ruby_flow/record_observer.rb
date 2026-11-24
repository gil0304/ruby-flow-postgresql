# frozen_string_literal: true

module RubyFlow
  # モデルに include すると、トランザクション確定(after_commit)/取り消し(after_rollback)時に
  # 「実際に DB に反映された（またはされなかった）行」を許可列だけ記録する。
  # この処理自体は lib/ にあり TracePoint の対象外なので、models.rb の実行行には混ざらない。
  module RecordObserver
    def self.included(base)
      base.after_commit do
        action = if destroyed? then "delete"
                 elsif previously_new_record? then "insert"
                 else "update"
                 end
        RubyFlow.record_db_change(self, action: action, committed: true)
      end
      base.after_rollback do
        action = destroyed? ? "delete" : (new_record? ? "insert" : "update")
        RubyFlow.record_db_change(self, action: action, committed: false)
      end
    end
  end
end
