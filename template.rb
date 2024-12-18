require "psych"
require "bundler"

# internal constants for the template
RAILS_GEM_VERSION = Gem::Version.new(Rails::VERSION::STRING).freeze
RAILS_8_VERSION = Gem::Version.new("8.0.0").freeze
AT_LEAST_RAILS_8 = RAILS_GEM_VERSION.release >= RAILS_8_VERSION

SKIP_SOLID_QUEUE = ENV.fetch("SKIP_SOLID_QUEUE", false).freeze
QUEUE_DB = ENV.fetch("QUEUE_DB", "queue").freeze
JOBS_ROUTE = ENV.fetch("JOBS_ROUTE", "/manage/jobs").freeze
JOBS_CONTROLLER = ENV.fetch("JOBS_CONTROLLER", "AdminController").freeze

SKIP_SOLID_CACHE = ENV.fetch("SKIP_SOLID_CACHE", false).freeze
CACHE_DB = ENV.fetch("CACHE_DB", "cache").freeze
SKIP_DEV_CACHE = ENV.fetch("SKIP_DEV_CACHE", false).freeze

SKIP_LITESTREAM = ENV.fetch("SKIP_LITESTREAM", true).freeze
SKIP_LITESTREAM_CREDS = ENV.fetch("SKIP_LITESTREAM_CREDS", false).freeze
LITESTREAM_ROUTE = ENV.fetch("LITESTREAM_ROUTE", "/manage/litestream").freeze

SKIP_SOLID_ERRORS = ENV.fetch("SKIP_SOLID_ERRORS", false).freeze
ERRORS_DB = ENV.fetch("ERRORS_DB", "errors").freeze
ERRORS_ROUTE = ENV.fetch("ERRORS_ROUTE", "/manage/errors").freeze

SKIP_SOLID_CABLE = ENV.fetch("SKIP_SOLID_CABLE", false).freeze
CABLE_DB = ENV.fetch("CABLE_DB", "cable").freeze

# ------------------------------------------------------------------------------

PUMA_FILE = "config/puma.rb".freeze
CONFIGURATION_FILE = "config/application.rb".freeze
DATABASE_FILE = "config/database.yml".freeze
ROUTES_FILE = "config/routes.rb".freeze
CACHE_FILE = "config/cache.yml".freeze
QUEUE_FILE = "config/queue.yml".freeze
CABLE_FILE = "config/cable.yml".freeze
LITESTREAM_FILE = "config/initializers/litestream.rb".freeze

CONFIGURATION_REGEX = /^([ \t]*).*?(?=\n\s*end\nend)$/

class DatabaseYAML
  COMMENTED_PROD_DATABASE = "# database: path/to/persistent/storage/production.sqlite3"
  UNCOMMENTED_PROD_DATABASE = "database: path/to/persistent/storage/production.sqlite3"
  attr_reader :content

  def initialize(path: nil, content: nil)
    @content = content ? content : File.read(path)
    # if the production environment has the default commented database value,
    # uncomment it so that the value can be parsed. We will comment it out
    # again at the end of the transformations.
    @content.gsub!(COMMENTED_PROD_DATABASE, UNCOMMENTED_PROD_DATABASE)
    @stream = Psych.parse_stream(@content)
    @emission_stream = Psych::Nodes::Stream.new
    @emission_document = Psych::Nodes::Document.new
    @emission_mapping = Psych::Nodes::Mapping.new
  end

  def add_database(name)
    root = @stream.children.first.root
    root.children.each_slice(2).map do |scalar, mapping|
      next unless scalar.is_a?(Psych::Nodes::Scalar)
      next unless mapping.is_a?(Psych::Nodes::Mapping)
      next unless mapping.anchor.nil? || mapping.anchor.empty?
      next if mapping.children.each_slice(2).any? do |key, value|
        key.is_a?(Psych::Nodes::Scalar) && key.value == name && value.is_a?(Psych::Nodes::Alias) && value.anchor == name
      end

      new_mapping = Psych::Nodes::Mapping.new
      if mapping.children.first.value == "<<" # 2-tiered environment
        new_mapping.children.concat [
          Psych::Nodes::Scalar.new("primary"),
          mapping,
          Psych::Nodes::Scalar.new(name),
          Psych::Nodes::Alias.new(name),
        ]
      else # 3-tiered environment
        new_mapping.children.concat mapping.children
        new_mapping.children.concat [
          Psych::Nodes::Scalar.new(name),
          Psych::Nodes::Alias.new(name),
        ]
      end

      old_environment_entry = emit_pair(scalar, mapping)
      new_environment_entry = emit_pair(scalar, new_mapping)

      [scalar.value, old_environment_entry, new_environment_entry]
    end.compact!
  end

  def new_database(name)
    db = Psych::Nodes::Mapping.new(name)
    db.children.concat [
      Psych::Nodes::Scalar.new("<<"),
      Psych::Nodes::Alias.new("default"),
      Psych::Nodes::Scalar.new("migrations_paths"),
      Psych::Nodes::Scalar.new("db/#{name}_migrate"),
      Psych::Nodes::Scalar.new("database"),
      Psych::Nodes::Scalar.new("storage/<%= Rails.env %>-#{name}.sqlite3"),
    ]
    "\n" + emit_pair(Psych::Nodes::Scalar.new(name), db)
  end

  def database_def_regex(name)
    /#{name}: &#{name}\n(?:[ \t]+.*\n)+/
  end

  def emit_pair(scalar, mapping)
    @emission_mapping.children.clear.concat [scalar, mapping]
    @emission_document.children.clear.concat [@emission_mapping]
    @emission_stream.children.clear.concat [@emission_document]
    output = @emission_stream.yaml.gsub!(/^---/, '').strip!
    # if the production environment had the default commented database value,
    # make sure to comment it out now when emitting the
    output.gsub!(UNCOMMENTED_PROD_DATABASE, COMMENTED_PROD_DATABASE)
    output
  end
end

def file_includes?(path, check)
  destination = File.expand_path(path, destination_root)
  return false unless File.exist?(destination)
  content = File.read(destination)
  check.is_a?(Regexp) ? content.match?(check) : content.include?(check)
end

def run_or_error(command, config = {})
  result = in_root { run command, config }

  if result
    return true
  else
    say_status :error, "Failed to run `#{command}`. Resolve and try again", :red
    exit 1
  end
end

def add_gem(*args)
  name, *versions = args
  return if file_includes?("Gemfile.lock", "    #{name}")
  return if file_includes?("Gemfile", /gem ['"]#{name}['"]/)

  gem(*args)
end

def bundle_install
  ::Bundler.with_unbundled_env do
    run_or_error 'bundle install'
  end
end

def ensure_clean_git!
  git_repo = run("git rev-parse --git-dir", capture: true) # Check if it's a git repo first
  if !git_repo || run("git status --porcelain", capture: true).present?
    say "ERROR: You have uncommitted changes. Please commit or stash them:", :red
    exit 1
  end
end

# ------------------------------------------------------------------------------

# Ensure we have a clean git
ensure_clean_git!

# Ensure the sqlite3 gem is installed
add_gem "sqlite3", "~> 2.0", comment: "Use SQLite as the database engine"

# Ensure all SQLite connections are properly configured
if not AT_LEAST_RAILS_8
  add_gem "activerecord-enhancedsqlite3-adapter", "~> 0.8.0", comment: "Ensure all SQLite connections are properly configured"
end

git(add: ".") && git(commit: %( -m 'enhance sqlite' ))

# Add Solid Queue
unless SKIP_SOLID_QUEUE
  # 1. add the appropriate solid_queue gem version
  add_gem "solid_queue", "~> 0.9", comment: "Add Solid Queue for background jobs"

  # 2. install the gem
  bundle_install

  # 3. define the new database configuration
  database_yaml = DatabaseYAML.new path: File.expand_path(DATABASE_FILE, destination_root)
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  insert_into_file DATABASE_FILE,
                   database_yaml.new_database(QUEUE_DB) + "\n",
                   after: database_yaml.database_def_regex("default"),
                   verbose: false
  say_status :def_db, "#{QUEUE_DB} (database.yml)"

  # 4. add the new database configuration to all environments
  database_yaml.add_database(QUEUE_DB).each do |environment, old_environment_entry, new_environment_entry|
    # NOTE: this `gsub_file` call is idempotent because we are only finding and replacing plain strings.
    gsub_file DATABASE_FILE,
              old_environment_entry,
              new_environment_entry,
              verbose: false
    say_status :add_db, "#{QUEUE_DB} -> #{environment} (database.yml)"
  end

  # 5. run the Solid Queue installation generator
  # NOTE: we run the command directly instead of via the `generate` helper
  # because that doesn't allow passing arbitrary environment variables.
  run_or_error "bin/rails generate solid_queue:install", env: { "DATABASE" => QUEUE_DB }
  git checkout: "-- config/environments/production.rb"

  # 6. run the migrations for the new database
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  run_or_error "bin/rails db:prepare", env: { "DATABASE" => QUEUE_DB }

  # 7. configure the application to use Solid Queue in all environments with the new database
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  queue_adapter = "config.active_job.queue_adapter"
  if not file_includes?(CONFIGURATION_FILE, queue_adapter)
    insert_into_file CONFIGURATION_FILE, after: CONFIGURATION_REGEX do
      [
        "",
        "",
        "\\1# Use Solid Queue for background jobs",
        "\\1#{queue_adapter} = :solid_queue",
      ].join("\n")
    end
  end

  connects_to = "config.solid_queue.connects_to"
  if not file_includes?(CONFIGURATION_FILE, connects_to)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(queue_adapter)}.*$/ do
      [
        "",
        "\\1#{connects_to} = {database: {writing: :#{QUEUE_DB}}}",
      ].join("\n")
    end
  end

  silence_polling = "config.solid_queue.silence_polling"
  if not file_includes?(CONFIGURATION_FILE, silence_polling)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(connects_to)}.*$/ do
      [
        "",
        "\\1#{silence_polling} = true",
      ].join("\n")
    end
  end

  # 8. add the Solid Queue plugin to Puma
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  plugin = "plugin :solid_queue"
  if not file_includes?(PUMA_FILE, plugin)
    insert_into_file PUMA_FILE, after: "plugin :tmp_restart" do
      [
        "",
        "# Allow puma to manage Solid Queue's supervisor process",
        plugin
      ].join("\n")
    end
  end

  # 9. add the Solid Queue engine to the application
  add_gem "mission_control-jobs", "~> 0.3", comment: "Add a web UI for Solid Queue"

  # 10. mount the Solid Queue engine
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  mount_mission_control_jobs = %Q{mount MissionControl::Jobs::Engine, at: "#{JOBS_ROUTE}"}
  if not file_includes?(ROUTES_FILE, mount_mission_control_jobs)
    insert_into_file ROUTES_FILE,  after: /^([ \t]*).*rails_health_check$/ do
      [
        "",
        "",
        "\\1#{mount_mission_control_jobs}"
      ].join("\n")
    end
  end

  jobs_controller = if JOBS_CONTROLLER.safe_constantize.nil?
    say_status :warning, "The JOBS_CONTROLLER class `#{JOBS_CONTROLLER}` does not exist. Generating a basic secure controller instead.", :blue
    create_file "app/controllers/mission_control/base_controller.rb", <<~RUBY
      module MissionControl
        mattr_writer :username
        mattr_writer :password

        class << self
          # use method instead of attr_accessor to ensure
          # this works if variable set after SolidErrors is loaded
          def username
            @username ||= @@username || ENV.fetch("MISSION_CONTROL_USERNAME", "admin")
          end

          def password
            @password ||= @@password || ENV.fetch("MISSION_CONTROL_PASSWORD", SecureRandom.hex(16))
          end
        end

        class BaseController < ActionController::Base
          protect_from_forgery with: :exception

          http_basic_authenticate_with name: MissionControl.username, password: MissionControl.password
        end
      end
    RUBY
    "MissionControl::BaseController"
  else
    JOBS_CONTROLLER
  end
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  base_controller_class = "config.mission_control.jobs.base_controller_class"
  if not file_includes?(CONFIGURATION_FILE, base_controller_class)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(connects_to)}.*$/ do
      [
        "",
        "\\1# Ensure authorization is enabled for the Solid Queue web UI",
        "\\1#{base_controller_class} = \"#{jobs_controller}\"",
      ].join("\n")
    end
  end

  # Commit
  git(add: ".") && git(commit: %( -m 'add solid queue' ))
end

# Add Solid Cache
unless SKIP_SOLID_CACHE
  # 1. add the appropriate solid_cache gem version
  add_gem "solid_cache", "~> 1.0", comment: "Add Solid Cache as an Active Support cache store"

  # 2. install the gem
  bundle_install

  # 3. define the new database configuration
  database_yaml = DatabaseYAML.new path: File.expand_path(DATABASE_FILE, destination_root)
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  insert_into_file DATABASE_FILE,
                   database_yaml.new_database(CACHE_DB) + "\n",
                   after: database_yaml.database_def_regex("default"),
                   verbose: false
  say_status :def_db, "#{CACHE_DB} (database.yml)"

  # 4. add the new database configuration to all environments
  database_yaml.add_database(CACHE_DB).each do |environment, old_environment_entry, new_environment_entry|
    # NOTE: this `gsub_file` call is idempotent because we are only finding and replacing plain strings.
    gsub_file DATABASE_FILE,
              old_environment_entry,
              new_environment_entry,
              verbose: false
    say_status :add_db, "#{CACHE_DB} -> #{environment} (database.yml)"
  end

  # 5. run the Solid Cache installation generator
  # NOTE: we run the command directly instead of via the `generate` helper
  # because that doesn't allow passing arbitrary environment variables.
  run_or_error "bin/rails generate solid_cache:install", env: { "DATABASE" => CACHE_DB }
  git checkout: "-- config/environments/production.rb"

  # 6. run the migrations for the new database
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  run_or_error "bin/rails db:prepare", env: { "DATABASE" => CACHE_DB }

  # 7. configure Solid Cache to use the new database
  # NOTE: this `gsub_file` call is idempotent because we are only finding and replacing plain strings.
  gsub_file CACHE_FILE,
            "database: <%= Rails.env %>",
            "database: #{CACHE_DB}"
  gsub_file CACHE_FILE,
            "database: cache",
            "database: #{CACHE_DB}"

  # 8. configure Solid Cache as the cache store
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  cache_store = "config.cache_store = :solid_cache_store"
  if not file_includes?(CONFIGURATION_FILE, cache_store)
    insert_into_file CONFIGURATION_FILE, after: CONFIGURATION_REGEX do
      [
        "",
        "",
        "\\1# Configure Solid Cache as the cache store",
        "\\1#{cache_store}",
      ].join("\n")
    end
  end

  # 9. optionally enable the cache in development
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  if not SKIP_DEV_CACHE
    run_or_error "bin/rails dev:cache"
  end

  # Commit
  git(add: ".") && git(commit: %( -m 'add solid cache' ))
end

# Add Solid Cable
unless SKIP_SOLID_CABLE
  # 1. add the appropriate solid_errors gem version
  add_gem "solid_cable", "~> 3.0", comment: "Add Solid Cable for web sockets"

  # 2. install the gem
  bundle_install

  # 3. define the new database configuration
  database_yaml = DatabaseYAML.new path: File.expand_path(DATABASE_FILE, destination_root)
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  insert_into_file DATABASE_FILE,
                  database_yaml.new_database(CABLE_DB) + "\n",
                  after: database_yaml.database_def_regex("default"),
                  verbose: false
  say_status :def_db, "#{CABLE_DB} (database.yml)"

  # 4. add the new database configuration to all environments
  database_yaml.add_database(CABLE_DB).each do |environment, old_environment_entry, new_environment_entry|
    # NOTE: this `gsub_file` call is idempotent because we are only finding and replacing plain strings.
    gsub_file DATABASE_FILE,
              old_environment_entry,
              new_environment_entry,
              verbose: false
    say_status :add_db, "#{CABLE_DB} -> #{environment} (database.yml)"
  end

  # 5. run the Solid Errors installation generator
  # NOTE: we run the command directly instead of via the `generate` helper
  # because that doesn't allow passing arbitrary environment variables.
  run_or_error "bin/rails generate solid_cable:install", env: { "DATABASE" => CABLE_DB }
  git checkout: "-- config/environments/production.rb"

  # 6. run the migrations for the new database
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  run_or_error "bin/rails db:prepare", env: { "DATABASE" => CABLE_DB }

  # 7. configure the application to use Solid Cable in all environments with the new database
  remove_file(CABLE_FILE)
  create_file(CABLE_FILE, <<~YAML)
    default: &default
      adapter: solid_cable
      polling_interval: 1.second
      keep_messages_around_for: 1.day
      connects_to:
        database:
          writing: #{CABLE_DB}

    development:
      <<: *default
      silence_polling: true

    test:
      <<: *default

    production:
      <<: *default
      polling_interval: 0.1.seconds
  YAML

  # Commit
  git(add: ".") && git(commit: %( -m 'add solid cable' ))
end

# Add Litestream
unless SKIP_LITESTREAM
  # 1. add the litestream gem
  add_gem "litestream", "~> 0.11.0", comment: "Ensure all SQLite databases are backed up"

  # 2. install the gem
  bundle_install

  # 3. run the Litestream installation generator
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  run_or_error "bin/rails generate litestream:install"

  # 4. add the Litestream plugin to Puma
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  insert_into_file PUMA_FILE, after: "plugin :tmp_restart" do
    [
      "",
      "# Allow puma to manage Litestream replication process",
      "plugin :litestream if ENV[\"RAILS_ENV\"] == \"production\""
    ].join("\n")
  end

  # 5. mount the Litestream engine
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  mount_litestream_jobs = %Q{mount Litestream::Engine, at: "#{LITESTREAM_ROUTE}"}
  if not file_includes?(ROUTES_FILE, mount_litestream_jobs)
    insert_into_file ROUTES_FILE,  after: /^([ \t]*).*rails_health_check$/ do
      [
        "",
        "",
        "\\1#{mount_litestream_jobs}"
      ].join("\n")
    end
  end

  # 6. Secure the Litestream dashboard
  # NOTE: `insert_into_file` with plain replacement text will be idempotent.
  insert_into_file LITESTREAM_FILE, before: "Rails.application.configure do" do
    [
      "# Ensure authorization is enabled for the Litestream web UI",
      "Litestream.username = ENV[\"LITESTREAM_USER\"]",
      "Litestream.password = ENV[\"LITESTREAM_PASSWORD\"]",
      "",
      "",
    ].join("\n")
  end

  # 7. Add a recurring task to verify Litestream backups
  old_dispatcher_entry = <<~YML
    dispatchers:
      - polling_interval: 1
        batch_size: 500
  YML
  new_dispatcher_entry = <<~YML
    dispatchers:
      - polling_interval: 1
        batch_size: 500
        recurring_tasks:
          periodic_litestream_backup_verfication_job:
            class: Litestream::VerificationJob
            args: []
            schedule: every day at 1am EST
  YML
  gsub_file QUEUE_FILE,
            old_dispatcher_entry,
            new_dispatcher_entry

  # 8. at the end of the Rails process, configure the Litestream engine
  after_bundle do
    say_status :NOTE, "Litestream requires an S3-compatible storage provider, like AWS S3, DigitalOcean Spaces, Google Cloud Storage, etc.", :blue
    if not SKIP_LITESTREAM_CREDS
      uncomment_lines LITESTREAM_FILE, /litestream_credentials/

      say_status :NOTE, <<~MESSAGE, :blue
        Edit your application's credentials to store your bucket details with:
            bin/rails credentials:edit
        Supply the necessary credentials for your S3-compatible storage provider in the following format:
            litestream:
              replica_bucket: <your-bucket-name>
              replica_key_id: <public-key>
              replica_access_key: <private-key>
        You can confirm that everything is configured correctly by validating the output of the following command:
            bin/rails litestream:env
      MESSAGE
    else
      say_status :NOTE, <<~MESSAGE, :blue
        You will need to configure Litestream by editing the configuration file at config/initializers/litestream.rb
      MESSAGE
    end
  end

  # Commit
  git(add: ".") && git(commit: %( -m 'add litecache' ))
end

# Add Solid Errors
unless SKIP_SOLID_ERRORS
  # 1. add the solid_errors gem
  add_gem "solid_errors", "~> 0.5", comment: "Add Solid Errors for error monitoring"

  # 2. install the gem
  bundle_install

  # 3. define the new database configuration
  database_yaml = DatabaseYAML.new path: File.expand_path(DATABASE_FILE, destination_root)
  # NOTE: this `insert_into_file` call is idempotent because we are only inserting a plain string.
  insert_into_file DATABASE_FILE,
                  database_yaml.new_database(ERRORS_DB) + "\n",
                  after: database_yaml.database_def_regex("default"),
                  verbose: false
  say_status :def_db, "#{ERRORS_DB} (database.yml)"

  # 4. add the new database configuration to all environments
  database_yaml.add_database(ERRORS_DB).each do |environment, old_environment_entry, new_environment_entry|
    # NOTE: this `gsub_file` call is idempotent because we are only finding and replacing plain strings.
    gsub_file DATABASE_FILE,
              old_environment_entry,
              new_environment_entry,
              verbose: false
    say_status :add_db, "#{ERRORS_DB} -> #{environment} (database.yml)"
  end

  # 5. run the Solid Errors installation generator
  # NOTE: we run the command directly instead of via the `generate` helper
  # because that doesn't allow passing arbitrary environment variables.
  run_or_error "bin/rails generate solid_errors:install", env: { "DATABASE" => ERRORS_DB }
  git checkout: "-- config/environments/production.rb"

  # 6. prepare the new database
  # NOTE: we run the command directly instead of via the `rails_command` helper
  # because that runs `bin/rails` through Ruby, which we can't test properly.
  run_or_error "bin/rails db:prepare", env: { "DATABASE" => ERRORS_DB }

  # 7. configure the application to use Solid Errors in all environments with the new database
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  connects_to = "config.solid_errors.connects_to"
  if not file_includes?(CONFIGURATION_FILE, connects_to)
    insert_into_file CONFIGURATION_FILE, after: CONFIGURATION_REGEX do
      [
        "",
        "",
        "\\1# Configure Solid Errors",
        "\\1#{connects_to} = {database: {writing: :#{ERRORS_DB}}}",
      ].join("\n")
    end
  end

  # 8. configure Solid Errors to send emails when errors occur
  send_emails = "config.solid_errors.send_emails"
  if not file_includes?(CONFIGURATION_FILE, send_emails)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(connects_to)}.*$/ do
      [
        "",
        "\\1#{send_emails} = ENV[\"SOLID_ERRORS_SEND_EMAILS\"]",
      ].join("\n")
    end
  end

  email_from = "config.solid_errors.email_from"
  if not file_includes?(CONFIGURATION_FILE, email_from)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(send_emails)}.*$/ do
      [
        "",
        "\\1#{email_from} = ENV[\"SOLID_ERRORS_EMAIL_FROM\"]",
      ].join("\n")
    end
  end

  email_to = "config.solid_errors.email_to"
  if not file_includes?(CONFIGURATION_FILE, email_to)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(email_from)}.*$/ do
      [
        "",
        "\\1#{email_to} = ENV[\"SOLID_ERRORS_EMAIL_TO\"]",
      ].join("\n")
    end
  end

  # 9. mount the Solid Errors engine
  # NOTE: `insert_into_file` with replacement text that contains regex backreferences will not be idempotent,
  # so we need to check if the line is already present before adding it.
  mount_solid_errors_engine = %Q{mount SolidErrors::Engine, at: "#{ERRORS_ROUTE}"}
  if not file_includes?(ROUTES_FILE, mount_solid_errors_engine)
    insert_into_file ROUTES_FILE,  after: /^([ \t]*).*rails_health_check$/ do
      [
        "",
        "",
        "\\1#{mount_solid_errors_engine}"
      ].join("\n")
    end
  end

  # 10. secure the Solid Errors web dashboard
  username = "config.solid_errors.username"
  if not file_includes?(CONFIGURATION_FILE, username)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(email_to)}.*$/ do
      [
        "",
        "\\1#{username} = ENV[\"SOLID_ERRORS_USERNAME\"]",
      ].join("\n")
    end
  end

  password = "config.solid_errors.password"
  if not file_includes?(CONFIGURATION_FILE, password)
    insert_into_file CONFIGURATION_FILE, after: /^([ \t]*)#{Regexp.escape(username)}.*$/ do
      [
        "",
        "\\1#{password} = ENV[\"SOLID_ERRORS_PASSWORD\"]",
      ].join("\n")
    end
  end

  # Commit
  git(add: ".") && git(commit: %( -m 'add solid errors' ))
end
