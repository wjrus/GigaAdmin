ENV["RAILS_ENV"] ||= "test"
# Existing controller fixtures exercise Google authentication. Local-auth tests
# explicitly select their mode; never inherit a developer's login configuration.
ENV["GIGAADMIN_AUTH_MODE"] = "google"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    include ActiveSupport::Testing::TimeHelpers

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  # Exercise the authenticated data request separately from the fast page shell.
  # Keep ordinary `get` for navigation, authentication, exports, and partials.
  def get_content(path, **options)
    headers = (options.delete(:headers) || {}).merge("Turbo-Frame" => "page-content")
    get(path, **options, headers: headers)
  end
end
