require 'resque/server'
#require 'sidekiq/web'
#require 'sidekiq_status/web'

Owl::Application.routes.draw do
  @xyz_constraints = {:zoom => /\d+/, :x => /\d+/, :y => /\d+/}
  @range_constraints = {:zoom => /\d+/, :x1 => /\d+/, :y1 => /\d+/, :x2 => /\d+/, :y2 => /\d+/}

  # The priority is based upon order of creation:
  # first created -> highest priority.

  # Tile operations
  get 'api/0.1/changesets/:zoom/:x/:y.atom' => 'changeset_api#changesets_tile_atom', :constraints => @xyz_constrains, :format => 'atom'
  get 'api/0.1/changesets/:zoom/:x/:y.json' => 'changeset_api#changesets_tile_json', :constraints => @xyz_constrains, :format => 'json'

  get 'api/0.1/summary/:zoom/:x/:y' => 'changeset_api#summary_tile', :constraints => @xyz_constrains
  get 'api/0.1/summary/:zoom/:x1/:y1/:x2/:y2' => 'changeset_api#summary_tilerange', :constraints => @range_constrains, :format => 'json'

  # Map API
  get 'api/0.1/kothic/:zoom/:x/:y.js' => 'map_api#kothic', :constraints => @xyz_constrains

  #get 'admin/:changeset_id' => 'application#test'
  get 'admin' => 'admin#index'
  get 'admin/process' => 'admin#process'
  post 'admin/go' => 'admin#go'
  get 'admin/go_latest' => 'admin#go_latest'
  post 'admin/spawn_workers' => 'admin#spawn_workers'

  mount Resque::Server.new, :at => "/resque"

  #mount Sidekiq::Web => '/sidekiq'
  #mount Sidekiq::Monitor::Engine => '/sidekiqm'
end
