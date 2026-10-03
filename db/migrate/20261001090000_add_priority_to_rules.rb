class AddPriorityToRules < ActiveRecord::Migration[8.1]
  def up
    add_column :rules, :priority, :integer, null: false, default: 0

    # Rules had no order, so give every family's existing rules one that is
    # stable and total: oldest first, the id breaking ties between rules created
    # in the same instant.
    execute <<~SQL.squish
      UPDATE rules
      SET priority = ranked.position
      FROM (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY family_id ORDER BY created_at, id) AS position
        FROM rules
      ) AS ranked
      WHERE rules.id = ranked.id
    SQL

    add_index :rules, [ :family_id, :priority ]
  end

  def down
    remove_index :rules, [ :family_id, :priority ]
    remove_column :rules, :priority
  end
end
