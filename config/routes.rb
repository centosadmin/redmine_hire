Rails.application.routes.draw do
  post 'issues/:id/refusal_response', to: 'redmine_hire#refusal_response'
  get '/redmine_hire/init_sidekiq_jobs', to: 'redmine_hire#init_sidekiq_jobs'
  get '/redmine_hire/destroy_sidekiq_jobs', to: 'redmine_hire#destroy_sidekiq_jobs'
  get 'redmine_hire/oauth', to: 'redmine_hire#oauth'
end
