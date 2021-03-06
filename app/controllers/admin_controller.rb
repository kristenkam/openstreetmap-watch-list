class AdminController < ActionController::Base
  protect_from_forgery

  def index
  end

  def go
    params[:ids].each_line do |line|
      Resque.enqueue(TilerWorker, line.to_i)
    end
    render nothing: true
  end

  def go_latest
    sql = "SELECT DISTINCT changeset_id FROM ways w WHERE NOT EXISTS
            (SELECT 1 FROM changeset_tiles WHERE changeset_id = w.changeset_id)
          ORDER BY changeset_id DESC
          LIMIT #{params[:limit]}"
    go_from_sql(sql)
    render nothing: true
  end

  def go_nearby
    sql = "SELECT DISTINCT changeset_id FROM ways w WHERE NOT EXISTS
            (SELECT 1 FROM changeset_tiles WHERE changeset_id = w.changeset_id)
          ORDER BY changeset_id DESC
          LIMIT #{params[:limit]}"
    go_from_sql(sql)
    render nothing: true
  end

  def go_from_sql(sql)
    for row in ActiveRecord::Base.connection.execute(sql) do
      Resque.enqueue(TilerWorker, row['changeset_id'].to_i)
    end
  end
end
