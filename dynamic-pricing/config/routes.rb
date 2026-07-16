Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get '/pricing', to: 'pricing#index'
    end
  end
end
