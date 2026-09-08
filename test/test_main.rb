# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'pathname'
require 'stringio'
require 'json'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── ENV / IO Helpers ─────────────────────────────────────────────────────────

# Temporarily apply ENV overrides, restoring the previous state afterwards.
# A nil value deletes the key, so a test can assert on a *missing* variable
# without the parent environment leaking in.
def with_env(overrides)
  saved = {}
  overrides.each_key { |k| saved[k] = ENV[k] }
  overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

# Runs the block with $stdout captured. Returns [block result, captured text].
def with_captured_stdout
  original = $stdout
  $stdout  = StringIO.new
  result   = yield
  [result, $stdout.string]
ensure
  $stdout = original
end

# Asserts the block aborts (SystemExit) and returns the stderr text it printed.
# Keeps `abort` messages out of the test report while still asserting them.
def abort_message
  original = $stderr
  captured = StringIO.new
  $stderr  = captured
  raised   = false
  begin
    yield
  rescue SystemExit
    raised = true
  end
  $stderr = original
  raise 'expected the block to abort with SystemExit, but it returned normally' unless raised

  captured.string
ensure
  $stderr = original
end

# Runs the block with $stderr suppressed, so an asserted `abort` message does
# not pollute the test report.
def quiet_stderr
  original = $stderr
  $stderr  = StringIO.new
  yield
ensure
  $stderr = original
end

# ─── Xcodeproj Mocks ──────────────────────────────────────────────────────────
# Lightweight stand-ins for the gem's objects, for the functions that only
# touch `name` / `build_settings` / `product_reference`.
MockBuildConfiguration = Struct.new(:name, :build_settings) do
  def resolve_build_setting(key) = build_settings[key]
end

MockProductReference = Struct.new(:path)

MockNativeTarget = Struct.new(:name, :build_configurations, :product_reference)

# Convenience: a target with Release/Debug configs sharing the same settings.
def mock_target(name: 'MyApp', settings: {}, product: 'MyApp.app', configs: nil)
  configs ||= %w[Release Debug].map { |c| MockBuildConfiguration.new(c, settings.dup) }
  MockNativeTarget.new(name, configs, product.nil? ? nil : MockProductReference.new(product))
end

# ─── Real Project Fixtures ────────────────────────────────────────────────────
# main.rb drives the real `xcodeproj` gem for `increment_key` /
# `get_value_from_plist`, so those are exercised against a genuine (but
# throwaway) project tree written inside a temp dir. Pure Ruby, no toolchain.
ProjectFixture = Struct.new(
  :params, :env, :root, :project_dir, :proj_path, :plist_path,
  keyword_init: true
)

# Builds <root>/<subdir>/<name>.xcodeproj (+ Info.plist, + optional shared
# scheme) and returns the `params` hash and ENV pair main.rb expects.
def build_xcode_project(root,
                        name: 'MyApp',
                        subdir: 'app',
                        plist: { 'CFBundleVersion' => '12', 'CFBundleShortVersionString' => '1.2.3' },
                        build_settings: {},
                        extra_targets: [],
                        scheme_configuration: nil,
                        configuration: 'Release',
                        targets: nil,
                        target_type: :application)
  project_dir = File.join(root, subdir)
  FileUtils.mkdir_p(project_dir)
  proj_path = File.join(project_dir, "#{name}.xcodeproj")

  project = Xcodeproj::Project.new(proj_path)
  target  = project.new_target(target_type, name, :ios, '13.0')

  plist_path = nil
  settings   = build_settings.dup
  if plist
    FileUtils.mkdir_p(File.join(project_dir, name))
    plist_path = File.join(project_dir, name, 'Info.plist')
    Xcodeproj::Plist.write_to_path(plist, plist_path)
    settings = { 'INFOPLIST_FILE' => "#{name}/Info.plist" }.merge(settings)
  end
  target.build_configurations.each { |c| c.build_settings.merge!(settings) }

  extra_targets.each do |spec|
    extra = project.new_target(spec.fetch(:type, :framework), spec.fetch(:name), :ios, '13.0')
    extra.build_configurations.each { |c| c.build_settings.merge!(spec.fetch(:build_settings, {})) }
  end

  project.save

  if scheme_configuration
    xcscheme = Xcodeproj::XCScheme.new
    xcscheme.configure_with_targets(target, nil)
    xcscheme.archive_action.build_configuration = scheme_configuration
    xcscheme.save_as(proj_path, name, true)
  end

  ProjectFixture.new(
    params: { xcodeproj: proj_path, scheme: name, configuration: configuration, targets: targets },
    env: { 'AC_REPOSITORY_DIR' => root, 'AC_PROJECT_PATH' => "#{subdir}/#{name}.xcodeproj" },
    root: root,
    project_dir: project_dir,
    proj_path: proj_path,
    plist_path: plist_path
  )
end

# Reads an Info.plist back off disk.
def read_plist(path)
  Xcodeproj::Plist.read_from_path(path.to_s)
end

# Minimal Net::HTTP response stand-in, so `appstore_version` never touches the
# network. It only calls `is_a?(Net::HTTPSuccess)` and `body`.
class FakeHTTPResponse
  attr_reader :body

  def initialize(body, success: true)
    @body    = body
    @success = success
  end

  def is_a?(klass)
    return @success if klass == Net::HTTPSuccess

    super
  end
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'Required libraries' do
  %w[open3 pathname json net/http].each do |lib|
    it "loads '#{lib}'" do
      expect { require lib }.not_to raise_error
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading contract' do
  it 'is requireable without executing the workflow step' do
    %w[
      env_has_key get_env xcode_project_file get_value_from_build_settings!
      runnable_target? update_target increment_key get_plist appstore_version
      get_build_number get_version_number get_value_from_plist
      calculate_build_number calculate_version_number
    ].each do |fn|
      expect(respond_to?(fn, true)).to be(true), "expected #{fn} to be defined by main.rb"
    end
  end

  it 'guards its top-level code with __FILE__ == $PROGRAM_NAME' do
    expect(File.read(MAIN_RB)).to include('if __FILE__ == $PROGRAM_NAME')
  end

  it 'guards the xcodeproj require so the file loads in a bare environment' do
    expect(File.read(MAIN_RB)).to match(/begin\s+require 'xcodeproj'\s+rescue LoadError/m)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  context 'positive path' do
    it 'returns the value when the variable is set' do
      with_env('AC_TEST_KEY' => 'value') do
        expect(env_has_key('AC_TEST_KEY')).to eq('value')
      end
    end

    it 'dereferences a $-prefixed indirection to another variable' do
      with_env('AC_TEST_KEY' => '$AC_TEST_TARGET', 'AC_TEST_TARGET' => 'resolved') do
        expect(env_has_key('AC_TEST_KEY')).to eq('resolved')
      end
    end

    it 'preserves values that merely contain a dollar sign' do
      with_env('AC_TEST_KEY' => 'a$b') do
        expect(env_has_key('AC_TEST_KEY')).to eq('a$b')
      end
    end

    it 'returns nil when the indirection target is itself unset' do
      with_env('AC_TEST_KEY' => '$AC_TEST_MISSING', 'AC_TEST_MISSING' => nil) do
        expect(env_has_key('AC_TEST_KEY')).to be_nil
      end
    end
  end

  context 'error branch' do
    it 'aborts when the variable is missing' do
      with_env('AC_TEST_KEY' => nil) do
        quiet_stderr { expect { env_has_key('AC_TEST_KEY') }.to raise_error(SystemExit) }
      end
    end

    it 'aborts when the variable is an empty string' do
      with_env('AC_TEST_KEY' => '') do
        quiet_stderr { expect { env_has_key('AC_TEST_KEY') }.to raise_error(SystemExit) }
      end
    end

    it 'names the missing variable in the abort message' do
      with_env('AC_TEST_KEY' => nil) do
        expect(abort_message { env_has_key('AC_TEST_KEY') }).to include('Missing AC_TEST_KEY.')
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env' do
  context 'positive path' do
    it 'returns the value when the variable is set' do
      with_env('AC_TEST_KEY' => 'value') do
        expect(get_env('AC_TEST_KEY')).to eq('value')
      end
    end

    it 'dereferences a $-prefixed indirection to another variable' do
      with_env('AC_TEST_KEY' => '$AC_TEST_TARGET', 'AC_TEST_TARGET' => 'resolved') do
        expect(get_env('AC_TEST_KEY')).to eq('resolved')
      end
    end
  end

  context 'empty / nil input' do
    it 'returns nil when the variable is missing' do
      with_env('AC_TEST_KEY' => nil) do
        expect(get_env('AC_TEST_KEY')).to be_nil
      end
    end

    it 'returns nil when the variable is an empty string' do
      with_env('AC_TEST_KEY' => '') do
        expect(get_env('AC_TEST_KEY')).to be_nil
      end
    end

    it 'never aborts, unlike env_has_key' do
      with_env('AC_TEST_KEY' => nil) do
        expect { get_env('AC_TEST_KEY') }.not_to raise_error
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#xcode_project_file' do
  let(:tmpdir) { Dir.mktmpdir('bvi_project_file') }

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'returns the joined path for an .xcodeproj project' do
      env = { 'AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => 'app/MyApp.xcodeproj' }
      with_env(env) do
        result, = with_captured_stdout { xcode_project_file }
        expect(result.to_s).to eq(File.join(tmpdir, 'app/MyApp.xcodeproj'))
      end
    end

    it 'resolves the sibling .xcodeproj for an .xcworkspace project' do
      FileUtils.mkdir_p(File.join(tmpdir, 'app', 'MyApp.xcodeproj'))
      FileUtils.mkdir_p(File.join(tmpdir, 'app', 'MyApp.xcworkspace'))
      env = { 'AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => 'app/MyApp.xcworkspace' }
      with_env(env) do
        result, = with_captured_stdout { xcode_project_file }
        expect(result.to_s).to eq(File.join(tmpdir, 'app', 'MyApp.xcodeproj'))
      end
    end

    it 'echoes the resolved project path and directory' do
      env = { 'AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => 'app/MyApp.xcodeproj' }
      with_env(env) do
        _result, output = with_captured_stdout { xcode_project_file }
        expect(output).to include('Project path:').and include('Project directory:')
      end
    end
  end

  context 'error branch' do
    it 'returns nil for a workspace with no sibling .xcodeproj' do
      FileUtils.mkdir_p(File.join(tmpdir, 'app', 'MyApp.xcworkspace'))
      env = { 'AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => 'app/MyApp.xcworkspace' }
      with_env(env) do
        result, = with_captured_stdout { xcode_project_file }
        expect(result).to be_nil
      end
    end

    it 'aborts when AC_REPOSITORY_DIR is missing' do
      with_env('AC_REPOSITORY_DIR' => nil, 'AC_PROJECT_PATH' => 'app/MyApp.xcodeproj') do
        expect(abort_message { xcode_project_file }).to include('Missing AC_REPOSITORY_DIR.')
      end
    end

    it 'aborts when AC_PROJECT_PATH is missing' do
      with_env('AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => nil) do
        expect(abort_message { xcode_project_file }).to include('Missing AC_PROJECT_PATH.')
      end
    end

    it 'aborts when AC_PROJECT_PATH is an empty string' do
      with_env('AC_REPOSITORY_DIR' => tmpdir, 'AC_PROJECT_PATH' => '') do
        expect(abort_message { xcode_project_file }).to include('Missing AC_PROJECT_PATH.')
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_value_from_build_settings!' do
  let(:target) do
    mock_target(configs: [
                  MockBuildConfiguration.new('Release', { 'MARKETING_VERSION' => '2.0.0' }),
                  MockBuildConfiguration.new('Debug',   { 'MARKETING_VERSION' => '1.0.0-dev' })
                ])
  end

  context 'positive path' do
    it 'returns the first resolvable value when no configuration is given' do
      expect(get_value_from_build_settings!(target, 'MARKETING_VERSION')).to eq('2.0.0')
    end

    it 'honours the requested configuration' do
      expect(get_value_from_build_settings!(target, 'MARKETING_VERSION', 'Debug')).to eq('1.0.0-dev')
    end

    it 'skips configurations that do not resolve the variable' do
      partial = mock_target(configs: [
                              MockBuildConfiguration.new('Release', {}),
                              MockBuildConfiguration.new('Debug', { 'CURRENT_PROJECT_VERSION' => '9' })
                            ])
      expect(get_value_from_build_settings!(partial, 'CURRENT_PROJECT_VERSION')).to eq('9')
    end
  end

  context 'error branch / empty input' do
    # Documents current behaviour: the method has no explicit `return nil`, so
    # it falls through to the value of `build_configurations.each`, i.e. the
    # array itself. That array is truthy, which is why the `a || b` fallbacks
    # in get_value_from_plist never reach their right-hand side.
    it 'falls through to the build_configurations array when nothing matches' do
      expect(get_value_from_build_settings!(target, 'NO_SUCH_SETTING'))
        .to eq(target.build_configurations)
    end

    it 'falls through when the requested configuration does not exist' do
      expect(get_value_from_build_settings!(target, 'MARKETING_VERSION', 'Nope'))
        .to eq(target.build_configurations)
    end

    it 'returns an empty array for a target with no build configurations' do
      expect(get_value_from_build_settings!(mock_target(configs: []), 'ANY')).to eq([])
    end

    it 'raises NoMethodError when the target is nil' do
      expect { get_value_from_build_settings!(nil, 'ANY') }.to raise_error(NoMethodError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#runnable_target?' do
  context 'positive path' do
    it 'accepts an .app product' do
      expect(runnable_target?(mock_target(product: 'MyApp.app'))).to be(true)
    end

    it 'accepts an .appex app extension' do
      expect(runnable_target?(mock_target(product: 'MyWidget.appex'))).to be(true)
    end
  end

  context 'error branch / empty input' do
    it 'rejects a .framework product' do
      expect(runnable_target?(mock_target(product: 'MyLib.framework'))).to be(false)
    end

    it 'rejects a static library product' do
      expect(runnable_target?(mock_target(product: 'libMyLib.a'))).to be(false)
    end

    it 'rejects a target with no product reference' do
      expect(runnable_target?(mock_target(product: nil))).to be(false)
    end

    it 'raises NoMethodError when the product reference has a nil path' do
      target = MockNativeTarget.new('Broken', [], MockProductReference.new(nil))
      expect { runnable_target?(target) }.to raise_error(NoMethodError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_plist' do
  let(:tmpdir) { Dir.mktmpdir('bvi_get_plist') }

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'returns the Info.plist path joined onto the project directory' do
      fx     = build_xcode_project(tmpdir)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        result, = with_captured_stdout { get_plist(fx.params, target) }
        expect(result.to_s).to eq(File.join(fx.project_dir, 'MyApp/Info.plist'))
      end
    end

    it 'resolves the configuration from the shared scheme when none is given' do
      fx = build_xcode_project(tmpdir, scheme_configuration: 'Release')
      params = fx.params.merge(configuration: nil)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        _result, output = with_captured_stdout { get_plist(params, target) }
        expect(output).to include('Archiving configuration: Release')
      end
    end

    it 'caches the scheme-resolved configuration back into params' do
      fx = build_xcode_project(tmpdir, scheme_configuration: 'Release')
      params = fx.params.merge(configuration: nil)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout { get_plist(params, target) }
      end
      expect(params[:configuration]).to eq('Release')
    end

    it 'prefers an explicit configuration over the scheme' do
      fx = build_xcode_project(tmpdir, scheme_configuration: 'Release')
      params = fx.params.merge(configuration: 'Debug')
      target = mock_target(configs: [
                             MockBuildConfiguration.new('Release', { 'INFOPLIST_FILE' => 'Release/Info.plist' }),
                             MockBuildConfiguration.new('Debug',   { 'INFOPLIST_FILE' => 'Debug/Info.plist' })
                           ])
      with_env(fx.env) do
        result, = with_captured_stdout { get_plist(params, target) }
        expect(result.to_s).to end_with('Debug/Info.plist')
      end
    end
  end

  context 'error branch' do
    it 'returns nil and warns when INFOPLIST_FILE is not in the build settings' do
      fx     = build_xcode_project(tmpdir, plist: nil)
      target = mock_target(settings: {})
      with_env(fx.env) do
        result, output = with_captured_stdout { get_plist(fx.params, target) }
        expect(result).to be_nil
        expect(output).to include("'Info.plist' file is not specified")
      end
    end

    it 'aborts when there is neither a configuration nor a shared scheme' do
      fx     = build_xcode_project(tmpdir)
      params = fx.params.merge(configuration: nil)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        expect(abort_message { get_plist(params, target) }).to include('Configuration not found')
      end
    end

    it 'raises SystemExit rather than returning when the configuration is unresolvable' do
      fx     = build_xcode_project(tmpdir)
      params = fx.params.merge(configuration: nil)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        quiet_stderr { expect { get_plist(params, target) }.to raise_error(SystemExit) }
      end
    end

    # Documents current behaviour: a configuration name that matches none of the
    # target's build configurations leaves build_config nil and the nil-unsafe
    # access surfaces as a NoMethodError.
    it 'raises NoMethodError when the configuration matches no build configuration' do
      fx     = build_xcode_project(tmpdir)
      params = fx.params.merge(configuration: 'NoSuchConfig')
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        expect { get_plist(params, target) }.to raise_error(NoMethodError)
      end
    end

    it 'aborts when AC_REPOSITORY_DIR is missing' do
      fx     = build_xcode_project(tmpdir)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env.merge('AC_REPOSITORY_DIR' => nil)) do
        expect(abort_message { get_plist(fx.params, target) }).to include('Missing AC_REPOSITORY_DIR.')
      end
    end

    it 'aborts when AC_PROJECT_PATH is missing' do
      fx     = build_xcode_project(tmpdir)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env.merge('AC_PROJECT_PATH' => nil)) do
        expect(abort_message { get_plist(fx.params, target) }).to include('Missing AC_PROJECT_PATH.')
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#update_target' do
  let(:tmpdir) { Dir.mktmpdir('bvi_update_target') }
  let(:fx)     { build_xcode_project(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'writes the value straight into Info.plist for a literal plist value' do
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('13')
    end

    it 'reports the direct Info.plist update on stdout' do
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include("Directly updating 'Info.plist'")
      end
    end

    it 'updates the referenced build setting for a $(VAR) plist value' do
      plist_path = File.join(fx.project_dir, 'MyApp', 'Info.plist')
      Xcodeproj::Plist.write_to_path({ 'CFBundleVersion' => '$(CURRENT_PROJECT_VERSION)' }, plist_path)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(target.build_configurations.map { |c| c.build_settings['CURRENT_PROJECT_VERSION'] })
        .to all(eq('13'))
    end

    it 'updates the referenced build setting for a ${VAR} plist value' do
      plist_path = File.join(fx.project_dir, 'MyApp', 'Info.plist')
      Xcodeproj::Plist.write_to_path({ 'CFBundleShortVersionString' => '${MARKETING_VERSION}' }, plist_path)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleShortVersionString', '2.0.0', 'MARKETING_VERSION')
        end
      end
      expect(target.build_configurations.map { |c| c.build_settings['MARKETING_VERSION'] })
        .to all(eq('2.0.0'))
    end

    it 'leaves Info.plist untouched when the value comes from a build setting' do
      plist_path = File.join(fx.project_dir, 'MyApp', 'Info.plist')
      Xcodeproj::Plist.write_to_path({ 'CFBundleVersion' => '$(CURRENT_PROJECT_VERSION)' }, plist_path)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(read_plist(plist_path)['CFBundleVersion']).to eq('$(CURRENT_PROJECT_VERSION)')
    end

    it 'sets the variable on configurations that generate their own plist' do
      target = mock_target(settings: {
                             'INFOPLIST_FILE' => 'MyApp/Info.plist',
                             'GENERATE_INFOPLIST_FILE' => 'YES'
                           })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(target.build_configurations.map { |c| c.build_settings['CURRENT_PROJECT_VERSION'] })
        .to all(eq('13'))
    end
  end

  context 'fallback branches' do
    it 'falls back to the build setting when the target has no Info.plist' do
      target = mock_target(settings: {})
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(target.build_configurations.map { |c| c.build_settings['CURRENT_PROJECT_VERSION'] })
        .to all(eq('13'))
    end

    it 'warns when no plist is found for the target' do
      target = mock_target(settings: {})
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('No plist found for target')
      end
    end

    it 'falls back to the build setting when the key is absent from Info.plist' do
      plist_path = File.join(fx.project_dir, 'MyApp', 'Info.plist')
      Xcodeproj::Plist.write_to_path({ 'CFBundleName' => 'MyApp' }, plist_path)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        with_captured_stdout do
          update_target(fx.params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(target.build_configurations.map { |c| c.build_settings['CURRENT_PROJECT_VERSION'] })
        .to all(eq('13'))
    end
  end

  context 'error branch' do
    it 'propagates the abort when the configuration cannot be resolved' do
      params = fx.params.merge(configuration: nil)
      target = mock_target(settings: { 'INFOPLIST_FILE' => 'MyApp/Info.plist' })
      with_env(fx.env) do
        quiet_stderr do
          expect { with_captured_stdout { update_target(params, target, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION') } }
            .to raise_error(SystemExit)
        end
      end
    end

    it 'raises NoMethodError when the target is nil' do
      with_env(fx.env) do
        expect { update_target(fx.params, nil, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION') }
          .to raise_error(NoMethodError)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#increment_key' do
  let(:tmpdir) { Dir.mktmpdir('bvi_increment_key') }

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'updates every runnable target when no target filter is given' do
      fx = build_xcode_project(tmpdir)
      with_env(fx.env) do
        with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('13')
    end

    it 'announces that it selected only apps and extensions' do
      fx = build_xcode_project(tmpdir)
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Selecting only apps and extensions').and include('Target: MyApp')
      end
    end

    it 'skips non-runnable targets such as frameworks' do
      fx = build_xcode_project(tmpdir, extra_targets: [{ name: 'MyLib', type: :framework }])
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Skipping target: MyLib')
      end
    end

    it 'selects targets by name when AC_TARGETS is set' do
      fx = build_xcode_project(tmpdir, targets: 'MyApp')
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Selecting target(s) by name').and include('Target: MyApp')
      end
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('13')
    end

    it 'splits a multi-target filter on the pipe symbol' do
      fx = build_xcode_project(tmpdir,
                               targets: 'MyApp|MyLib',
                               extra_targets: [{ name: 'MyLib', type: :framework }])
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Target: MyApp').and include('Target: MyLib')
      end
    end

    it 'persists the project after updating' do
      fx     = build_xcode_project(tmpdir, plist: nil)
      pbxproj = File.join(fx.proj_path, 'project.pbxproj')
      before  = File.read(pbxproj)
      with_env(fx.env) do
        with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '77', 'CURRENT_PROJECT_VERSION')
        end
      end
      expect(File.read(pbxproj)).not_to eq(before)
      expect(File.read(pbxproj)).to include('CURRENT_PROJECT_VERSION = 77')
    end
  end

  context 'error branch / empty input' do
    it 'treats an empty target filter as "all runnable targets"' do
      fx = build_xcode_project(tmpdir, targets: '')
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Selecting only apps and extensions')
      end
    end

    it 'skips every target when the filter matches nothing' do
      fx = build_xcode_project(tmpdir, targets: 'NoSuchTarget')
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          increment_key(fx.params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include('Skipping target: MyApp')
      end
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('12')
    end

    it 'raises when the project path does not exist' do
      params = { xcodeproj: File.join(tmpdir, 'Missing.xcodeproj'), scheme: 'MyApp', configuration: 'Release' }
      expect { with_captured_stdout { increment_key(params, 'CFBundleVersion', '13', 'CURRENT_PROJECT_VERSION') } }
        .to raise_error(StandardError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#appstore_version' do
  let(:success_body) { JSON.dump('resultCount' => 1, 'results' => [{ 'version' => '4.5.6' }]) }

  # Every example stubs Net::HTTP, so no request ever leaves the process.
  def stub_lookup(response)
    requested = []
    allow(Net::HTTP).to receive(:get_response) do |uri|
      requested << uri.to_s
      response
    end
    requested
  end

  context 'positive path' do
    it 'returns the version reported by the iTunes Search API' do
      stub_lookup(FakeHTTPResponse.new(success_body))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        result, = with_captured_stdout { appstore_version }
        expect(result).to eq('4.5.6')
      end
    end

    it 'looks the app up by bundle id' do
      requested = stub_lookup(FakeHTTPResponse.new(success_body))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        with_captured_stdout { appstore_version }
      end
      expect(requested.first).to eq('https://itunes.apple.com/lookup?bundleId=com.example.app')
    end

    it 'appends the country when AC_APPSTORE_COUNTRY is set' do
      requested = stub_lookup(FakeHTTPResponse.new(success_body))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => 'us') do
        with_captured_stdout { appstore_version }
      end
      expect(requested.first).to eq('https://itunes.apple.com/lookup?bundleId=com.example.app&country=us')
    end

    it 'mentions the country in the progress message' do
      stub_lookup(FakeHTTPResponse.new(success_body))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => 'de') do
        _r, output = with_captured_stdout { appstore_version }
        expect(output).to include('and country: de')
      end
    end
  end

  context 'error branch' do
    it 'aborts when the API returns a non-success status' do
      stub_lookup(FakeHTTPResponse.new('not found', success: false))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        message = abort_message { with_captured_stdout { appstore_version } }
        expect(message).to include('unexpected status code')
      end
    end

    it 'aborts when resultCount is zero' do
      stub_lookup(FakeHTTPResponse.new(JSON.dump('resultCount' => 0, 'results' => [])))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        message = abort_message { with_captured_stdout { appstore_version } }
        expect(message).to include('No app was found on the App Store')
      end
    end

    it 'aborts when the results array is empty despite a positive resultCount' do
      stub_lookup(FakeHTTPResponse.new(JSON.dump('resultCount' => 1, 'results' => [])))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        message = abort_message { with_captured_stdout { appstore_version } }
        expect(message).to include('No app was found on the App Store')
      end
    end

    it 'names the country in the not-found message' do
      stub_lookup(FakeHTTPResponse.new(JSON.dump('resultCount' => 0, 'results' => [])))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => 'fr') do
        message = abort_message { with_captured_stdout { appstore_version } }
        expect(message).to include("in country 'fr'")
      end
    end

    it 'aborts before any request when AC_BUNDLE_ID is missing' do
      allow(Net::HTTP).to receive(:get_response).and_raise('the network must not be touched')
      with_env('AC_BUNDLE_ID' => nil) do
        expect(abort_message { appstore_version }).to include('Missing AC_BUNDLE_ID.')
      end
    end

    it 'aborts when AC_BUNDLE_ID is an empty string' do
      allow(Net::HTTP).to receive(:get_response).and_raise('the network must not be touched')
      with_env('AC_BUNDLE_ID' => '') do
        quiet_stderr { expect { appstore_version }.to raise_error(SystemExit) }
      end
    end

    it 'raises when the API returns a malformed body' do
      stub_lookup(FakeHTTPResponse.new('<html>not json</html>'))
      with_env('AC_BUNDLE_ID' => 'com.example.app', 'AC_APPSTORE_COUNTRY' => nil) do
        expect { with_captured_stdout { appstore_version } }.to raise_error(JSON::ParserError)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_build_number' do
  context 'positive path' do
    it "reads CFBundleVersion from the project for the 'xcode' source" do
      allow(self).to receive(:get_value_from_plist).and_return('12')
      expect(get_build_number({}, 'xcode')).to eq('12')
    end

    it "passes CFBundleVersion / CURRENT_PROJECT_VERSION through for the 'xcode' source" do
      expect(self).to receive(:get_value_from_plist)
        .with({}, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION').and_return('12')
      get_build_number({}, 'xcode')
    end

    it "reads AC_IOS_BUILD_NUMBER for the 'env' source" do
      with_env('AC_IOS_BUILD_NUMBER' => '42') do
        expect(get_build_number({}, 'env')).to eq('42')
      end
    end
  end

  context 'error branch / empty input' do
    it "aborts when the 'env' source is selected but AC_IOS_BUILD_NUMBER is missing" do
      with_env('AC_IOS_BUILD_NUMBER' => nil) do
        expect(abort_message { get_build_number({}, 'env') }).to include('Missing AC_IOS_BUILD_NUMBER.')
      end
    end

    it "aborts when the 'env' source is selected but AC_IOS_BUILD_NUMBER is empty" do
      with_env('AC_IOS_BUILD_NUMBER' => '') do
        quiet_stderr { expect { get_build_number({}, 'env') }.to raise_error(SystemExit) }
      end
    end

    it 'returns nil for an unknown source' do
      expect(get_build_number({}, 'appstore')).to be_nil
    end

    it 'returns nil for a nil source' do
      expect(get_build_number({}, nil)).to be_nil
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_version_number' do
  context 'positive path' do
    it "reads CFBundleShortVersionString from the project for the 'xcode' source" do
      allow(self).to receive(:get_value_from_plist).and_return('1.2.3')
      expect(get_version_number({}, 'xcode')).to eq('1.2.3')
    end

    it "passes CFBundleShortVersionString / MARKETING_VERSION through for the 'xcode' source" do
      expect(self).to receive(:get_value_from_plist)
        .with({}, 'CFBundleShortVersionString', 'MARKETING_VERSION').and_return('1.2.3')
      get_version_number({}, 'xcode')
    end

    it "delegates to the App Store lookup for the 'appstore' source" do
      allow(self).to receive(:appstore_version).and_return('4.5.6')
      expect(get_version_number({}, 'appstore')).to eq('4.5.6')
    end

    it "reads AC_IOS_VERSION_NUMBER for the 'env' source" do
      with_env('AC_IOS_VERSION_NUMBER' => '9.9.9') do
        expect(get_version_number({}, 'env')).to eq('9.9.9')
      end
    end
  end

  context 'error branch / empty input' do
    it "aborts when the 'env' source is selected but AC_IOS_VERSION_NUMBER is missing" do
      with_env('AC_IOS_VERSION_NUMBER' => nil) do
        expect(abort_message { get_version_number({}, 'env') }).to include('Missing AC_IOS_VERSION_NUMBER.')
      end
    end

    it "aborts when the 'env' source is selected but AC_IOS_VERSION_NUMBER is empty" do
      with_env('AC_IOS_VERSION_NUMBER' => '') do
        quiet_stderr { expect { get_version_number({}, 'env') }.to raise_error(SystemExit) }
      end
    end

    it 'returns nil for an unknown source' do
      expect(get_version_number({}, 'nowhere')).to be_nil
    end

    it 'returns nil for a nil source' do
      expect(get_version_number({}, nil)).to be_nil
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_value_from_plist' do
  let(:tmpdir) { Dir.mktmpdir('bvi_value_from_plist') }

  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'returns a literal value straight from Info.plist' do
      fx = build_xcode_project(tmpdir)
      with_env(fx.env) do
        result, = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION')
        end
        expect(result).to eq('12')
      end
    end

    it 'resolves a $(VAR) placeholder from the build settings' do
      fx = build_xcode_project(
        tmpdir,
        plist: { 'CFBundleVersion' => '$(CURRENT_PROJECT_VERSION)' },
        build_settings: { 'CURRENT_PROJECT_VERSION' => '31' }
      )
      with_env(fx.env) do
        result, = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION')
        end
        expect(result).to eq('31')
      end
    end

    it 'resolves a ${VAR} placeholder from the build settings' do
      fx = build_xcode_project(
        tmpdir,
        plist: { 'CFBundleShortVersionString' => '${MARKETING_VERSION}' },
        build_settings: { 'MARKETING_VERSION' => '3.2.1' }
      )
      with_env(fx.env) do
        result, = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleShortVersionString', 'MARKETING_VERSION')
        end
        expect(result).to eq('3.2.1')
      end
    end

    it 'falls back to the build setting when the key is absent from Info.plist' do
      fx = build_xcode_project(
        tmpdir,
        plist: { 'CFBundleName' => 'MyApp' },
        build_settings: { 'CURRENT_PROJECT_VERSION' => '55' }
      )
      with_env(fx.env) do
        result, = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION')
        end
        expect(result).to eq('55')
      end
    end

    it 'warns when it has to fall back to the Xcode variable' do
      fx = build_xcode_project(
        tmpdir,
        plist: { 'CFBundleName' => 'MyApp' },
        build_settings: { 'CURRENT_PROJECT_VERSION' => '55' }
      )
      with_env(fx.env) do
        _r, output = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION')
        end
        expect(output).to include("No value for 'CFBundleVersion' was found in 'Info.plist'")
      end
    end

    it 'reads from the build settings when the project has no Info.plist at all' do
      fx = build_xcode_project(tmpdir, plist: nil, build_settings: { 'CURRENT_PROJECT_VERSION' => '64' })
      with_env(fx.env) do
        result, output = with_captured_stdout do
          get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION')
        end
        expect(result).to eq('64')
        expect(output).to include("Unable to read 'Info.plist' file")
      end
    end
  end

  context 'error branch' do
    # Documents current behaviour: with no application target, `get_plist`
    # receives nil and the nil-unsafe access surfaces as a NoMethodError.
    it 'raises NoMethodError when the project has no application target' do
      fx = build_xcode_project(tmpdir, target_type: :framework)
      with_env(fx.env) do
        expect { with_captured_stdout { get_value_from_plist(fx.params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION') } }
          .to raise_error(NoMethodError)
      end
    end

    it 'aborts when the configuration cannot be resolved' do
      fx     = build_xcode_project(tmpdir)
      params = fx.params.merge(configuration: nil)
      with_env(fx.env) do
        message = abort_message do
          with_captured_stdout { get_value_from_plist(params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION') }
        end
        expect(message).to include('Configuration not found')
      end
    end

    it 'raises when the project path does not exist' do
      params = { xcodeproj: File.join(tmpdir, 'Missing.xcodeproj'), scheme: 'MyApp', configuration: 'Release' }
      expect { with_captured_stdout { get_value_from_plist(params, 'CFBundleVersion', 'CURRENT_PROJECT_VERSION') } }
        .to raise_error(StandardError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#calculate_build_number' do
  context 'positive path' do
    it 'increments a single-component build number' do
      expect(calculate_build_number('12', 1)).to eq('13')
    end

    it 'increments only the last component of a dotted build number' do
      expect(calculate_build_number('1.2.3', 1)).to eq('1.2.4')
    end

    it 'accepts a string offset' do
      expect(calculate_build_number('12', '5')).to eq('17')
    end

    it 'supports a negative offset' do
      expect(calculate_build_number('12', '-2')).to eq('10')
    end

    it 'is a no-op for a zero offset' do
      expect(calculate_build_number('12', 0)).to eq('12')
    end

    it 'normalises leading zeros through the integer round-trip' do
      expect(calculate_build_number('007', 1)).to eq('8')
    end
  end

  context 'error branch / empty input' do
    # Documents current behaviour: a non-numeric build number degrades to 0
    # rather than failing, so the offset alone is returned.
    it 'treats a non-numeric build number as zero' do
      expect(calculate_build_number('abc', 1)).to eq('1')
    end

    it 'raises NoMethodError for an empty build number' do
      expect { calculate_build_number('', 1) }.to raise_error(NoMethodError)
    end

    it 'raises NoMethodError for a nil build number' do
      expect { calculate_build_number(nil, 1) }.to raise_error(NoMethodError)
    end

    # nil.to_i is 0 in Ruby, so a nil offset is a silent no-op rather than an error.
    it 'treats a nil offset as zero' do
      expect(calculate_build_number('12', nil)).to eq('12')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#calculate_version_number' do
  context 'positive path' do
    it 'bumps the patch component' do
      expect(calculate_version_number('1.2.3', 'patch', false, 1)).to eq('1.2.4')
    end

    it 'bumps the minor component and resets the patch' do
      expect(calculate_version_number('1.2.3', 'minor', false, 1)).to eq('1.3.0')
    end

    it 'bumps the major component and resets minor and patch' do
      expect(calculate_version_number('1.2.3', 'major', false, 1)).to eq('2.0.0')
    end

    it 'accepts a string offset' do
      expect(calculate_version_number('1.2.3', 'patch', false, '2')).to eq('1.2.5')
    end

    it 'supports a negative offset' do
      expect(calculate_version_number('1.5.3', 'minor', false, '-1')).to eq('1.4.0')
    end

    it 'extends a two-component version when bumping the patch' do
      expect(calculate_version_number('1.2', 'patch', false, 1)).to eq('1.2.1')
    end

    it 'returns the version unchanged for an unrecognised strategy' do
      expect(calculate_version_number('1.2.3', 'keep', false, 1)).to eq('1.2.3')
    end
  end

  context 'omit-zero-patch handling' do
    it 'drops a zero patch component when omit_zero is true' do
      expect(calculate_version_number('1.2.0', 'minor', true, 1)).to eq('1.3')
    end

    it 'keeps a zero patch component when omit_zero is false' do
      expect(calculate_version_number('1.2.0', 'minor', false, 1)).to eq('1.3.0')
    end

    it 'keeps a non-zero patch component when omit_zero is true' do
      expect(calculate_version_number('1.2.5', 'patch', true, 0)).to eq('1.2.5')
    end

    it 'drops the patch component of a major bump when omit_zero is true' do
      expect(calculate_version_number('1.2.3', 'major', true, 1)).to eq('2.0')
    end
  end

  context 'error branch / empty input' do
    # Documents current behaviour: an empty version yields a sparse array,
    # whose nil holes render as empty segments after `join('.')`.
    it 'produces a sparse version string for an empty input' do
      expect(calculate_version_number('', 'patch', false, 1)).to eq('..1')
    end

    it 'raises NoMethodError for a nil version' do
      expect { calculate_version_number(nil, 'patch', false, 1) }.to raise_error(NoMethodError)
    end

    it 'treats a non-numeric version as zero' do
      expect(calculate_version_number('abc', 'patch', false, 1)).to eq('0..1')
    end

    # nil.to_i is 0 in Ruby, so a nil offset is a silent no-op rather than an error.
    it 'treats a nil offset as zero' do
      expect(calculate_version_number('1.2.3', 'patch', false, nil)).to eq('1.2.3')
    end
  end
end

# ─── Subprocess Helpers ───────────────────────────────────────────────────────
# The guarded top-level block can only run as `ruby main.rb`, so the ENV
# validation and end-to-end cases spawn it as a child process.

# Directory where child processes drop their coverage snapshots, so the report
# reflects the guarded top-level block as well as the in-process functions.
COVERAGE_DIR = Dir.mktmpdir('bvi_cov')

# Preloaded into every child with `ruby -r<helper> main.rb`, which keeps
# main.rb as $PROGRAM_NAME so its top-level guard still fires.
COVERAGE_HELPER = File.join(COVERAGE_DIR, 'cov_helper.rb')
File.write(COVERAGE_HELPER, <<~RUBY)
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_DIR']
    next if dir.nil? || dir.empty?

    result = begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
    target = result.keys.find { |p| p.to_s.end_with?('main.rb') }
    next if target.nil?

    counts = result[target].map { |c| c.nil? ? '-' : c }.join(',')
    File.write(File.join(dir, "cov-\#{Process.pid}.txt"), counts)
  end
RUBY

# Merge every child snapshot into a single line-count array.
def subprocess_coverage
  Dir.glob(File.join(COVERAGE_DIR, 'cov-*.txt')).each_with_object([]) do |file, acc|
    File.read(file).split(',').each_with_index do |cell, i|
      next if cell == '-'

      acc[i] = (acc[i] || 0) + cell.to_i
    end
  end
end

# Run main.rb in a subprocess with the given ENV overrides. Every variable the
# step reads is explicitly unset first, so the parent environment can never
# leak into a validation test.
def run_main(env = {})
  child_env = {
    'AC_REPOSITORY_DIR'         => nil,
    'AC_PROJECT_PATH'           => nil,
    'AC_SCHEME'                 => nil,
    'AC_IOS_CONFIGURATION_NAME' => nil,
    'AC_TARGETS'                => nil,
    'AC_BUILD_NUMBER_SOURCE'    => nil,
    'AC_VERSION_NUMBER_SOURCE'  => nil,
    'AC_IOS_BUILD_NUMBER'       => nil,
    'AC_IOS_VERSION_NUMBER'     => nil,
    'AC_BUILD_OFFSET'           => nil,
    'AC_VERSION_OFFSET'         => nil,
    'AC_VERSION_STRATEGY'       => nil,
    'AC_OMIT_ZERO_PATCH_VERSION' => nil,
    'AC_ENV_FILE_PATH'          => nil,
    'AC_BUNDLE_ID'              => nil,
    'AC_APPSTORE_COUNTRY'       => nil
  }.merge(env)
  child_env['AC_TEST_COVERAGE_DIR'] = COVERAGE_DIR
  Open3.capture3(child_env, 'ruby', "-r#{COVERAGE_HELPER}", MAIN_RB)
end

# A complete, valid environment for an end-to-end run against `fx`.
def e2e_env(fx, overrides = {})
  fx.env.merge(
    'AC_SCHEME'                 => 'MyApp',
    'AC_IOS_CONFIGURATION_NAME' => 'Release',
    'AC_ENV_FILE_PATH'          => File.join(fx.root, 'env.sh')
  ).merge(overrides)
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess - main.rb)' do
  let(:tmpdir) { Dir.mktmpdir('bvi_env_validation') }
  let(:fx)     { build_xcode_project(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  shared_examples 'aborts with message' do |expected|
    it "exits non-zero and reports #{expected}" do
      _out, err, status = run_main(env_under_test)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include(expected)
    end
  end

  describe 'AC_SCHEME' do
    context 'when missing' do
      let(:env_under_test) { {} }
      include_examples 'aborts with message', 'Missing AC_SCHEME.'
    end

    context 'when empty' do
      let(:env_under_test) { { 'AC_SCHEME' => '' } }
      include_examples 'aborts with message', 'Missing AC_SCHEME.'
    end
  end

  describe 'AC_REPOSITORY_DIR' do
    context 'when missing' do
      let(:env_under_test) { { 'AC_SCHEME' => 'MyApp' } }
      include_examples 'aborts with message', 'Missing AC_REPOSITORY_DIR.'
    end

    context 'when empty' do
      let(:env_under_test) { { 'AC_SCHEME' => 'MyApp', 'AC_REPOSITORY_DIR' => '' } }
      include_examples 'aborts with message', 'Missing AC_REPOSITORY_DIR.'
    end
  end

  describe 'AC_PROJECT_PATH' do
    context 'when missing' do
      let(:env_under_test) { { 'AC_SCHEME' => 'MyApp', 'AC_REPOSITORY_DIR' => '/tmp' } }
      include_examples 'aborts with message', 'Missing AC_PROJECT_PATH.'
    end

    context 'when empty' do
      let(:env_under_test) do
        { 'AC_SCHEME' => 'MyApp', 'AC_REPOSITORY_DIR' => '/tmp', 'AC_PROJECT_PATH' => '' }
      end
      include_examples 'aborts with message', 'Missing AC_PROJECT_PATH.'
    end
  end

  describe 'AC_ENV_FILE_PATH' do
    it 'exits non-zero and reports it when missing' do
      env = e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode').merge('AC_ENV_FILE_PATH' => nil)
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_ENV_FILE_PATH.')
    end

    it 'exits non-zero and reports it when empty' do
      env = e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode').merge('AC_ENV_FILE_PATH' => '')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_ENV_FILE_PATH.')
    end
  end

  describe 'AC_IOS_BUILD_NUMBER' do
    it "aborts when the build number source is 'env' but the variable is missing" do
      env = e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'env')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_IOS_BUILD_NUMBER.')
    end

    it "aborts when the build number source is 'env' but the variable is empty" do
      env = e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'env', 'AC_IOS_BUILD_NUMBER' => '')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_IOS_BUILD_NUMBER.')
    end
  end

  describe 'AC_IOS_VERSION_NUMBER' do
    it "aborts when the version number source is 'env' but the variable is missing" do
      env = e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'env')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_IOS_VERSION_NUMBER.')
    end

    it "aborts when the version number source is 'env' but the variable is empty" do
      env = e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'env', 'AC_IOS_VERSION_NUMBER' => '')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_IOS_VERSION_NUMBER.')
    end
  end

  describe 'AC_BUNDLE_ID' do
    # AC_BUNDLE_ID is the very first thing appstore_version reads, so this
    # aborts before any HTTP request is attempted.
    it "aborts when the version number source is 'appstore' but the variable is missing" do
      env = e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'appstore')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_BUNDLE_ID.')
    end

    it "aborts when the version number source is 'appstore' but the variable is empty" do
      env = e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'appstore', 'AC_BUNDLE_ID' => '')
      _out, err, status = run_main(env)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Missing AC_BUNDLE_ID.')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'End-to-end (subprocess - main.rb)' do
  let(:tmpdir) { Dir.mktmpdir('bvi_e2e') }

  after { FileUtils.rm_rf(tmpdir) }

  context 'no source selected' do
    it 'exits 0 and skips the step when neither source is set' do
      fx = build_xcode_project(tmpdir)
      out, _err, status = run_main(e2e_env(fx))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Skipping this step..')
    end

    it 'does not write the env file when the step is skipped' do
      fx = build_xcode_project(tmpdir)
      run_main(e2e_env(fx))
      expect(File.exist?(File.join(fx.root, 'env.sh'))).to be(false)
    end
  end

  context 'build number from the Xcode project' do
    it 'bumps CFBundleVersion in Info.plist' do
      fx = build_xcode_project(tmpdir)
      _out, _err, status = run_main(
        e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode', 'AC_BUILD_OFFSET' => '1')
      )
      expect(status.exitstatus).to eq(0)
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('13')
    end

    it 'exports the new build number to the env file' do
      fx = build_xcode_project(tmpdir)
      run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode', 'AC_BUILD_OFFSET' => '1'))
      expect(File.read(File.join(fx.root, 'env.sh'))).to include('AC_IOS_NEW_BUILD_NUMBER=13')
    end

    it 'warns that the version number update is skipped' do
      fx = build_xcode_project(tmpdir)
      out, _err, _status = run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode'))
      expect(out).to include('No version number source specified')
    end

    it 'supports a negative build offset' do
      fx = build_xcode_project(tmpdir)
      run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode', 'AC_BUILD_OFFSET' => '-2'))
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('10')
    end
  end

  context 'build number from the environment' do
    it 'uses AC_IOS_BUILD_NUMBER as the base' do
      fx = build_xcode_project(tmpdir)
      _out, _err, status = run_main(
        e2e_env(fx,
                'AC_BUILD_NUMBER_SOURCE' => 'env',
                'AC_IOS_BUILD_NUMBER'    => '100',
                'AC_BUILD_OFFSET'        => '1')
      )
      expect(status.exitstatus).to eq(0)
      expect(read_plist(fx.plist_path)['CFBundleVersion']).to eq('101')
    end

    it 'reports the Appcircle build number' do
      fx = build_xcode_project(tmpdir)
      out, _err, _status = run_main(
        e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'env', 'AC_IOS_BUILD_NUMBER' => '100')
      )
      expect(out).to include('Appcircle Build Number: 100')
    end
  end

  context 'version number from the Xcode project' do
    it 'bumps the minor version and resets the patch' do
      fx = build_xcode_project(tmpdir)
      _out, _err, status = run_main(
        e2e_env(fx,
                'AC_VERSION_NUMBER_SOURCE' => 'xcode',
                'AC_VERSION_STRATEGY'      => 'minor',
                'AC_VERSION_OFFSET'        => '1')
      )
      expect(status.exitstatus).to eq(0)
      expect(read_plist(fx.plist_path)['CFBundleShortVersionString']).to eq('1.3.0')
    end

    it 'keeps the version unchanged for the default keep strategy' do
      fx = build_xcode_project(tmpdir)
      run_main(e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'xcode'))
      expect(read_plist(fx.plist_path)['CFBundleShortVersionString']).to eq('1.2.3')
    end

    it 'omits a zero patch component when AC_OMIT_ZERO_PATCH_VERSION is true' do
      fx = build_xcode_project(tmpdir)
      run_main(
        e2e_env(fx,
                'AC_VERSION_NUMBER_SOURCE'   => 'xcode',
                'AC_VERSION_STRATEGY'        => 'minor',
                'AC_VERSION_OFFSET'          => '1',
                'AC_OMIT_ZERO_PATCH_VERSION' => 'true')
      )
      expect(read_plist(fx.plist_path)['CFBundleShortVersionString']).to eq('1.3')
    end

    it 'exports the new version number to the env file' do
      fx = build_xcode_project(tmpdir)
      run_main(
        e2e_env(fx,
                'AC_VERSION_NUMBER_SOURCE' => 'xcode',
                'AC_VERSION_STRATEGY'      => 'major',
                'AC_VERSION_OFFSET'        => '1')
      )
      expect(File.read(File.join(fx.root, 'env.sh'))).to include('AC_IOS_NEW_VERSION_NUMBER=2.0.0')
    end

    it 'warns that the build number update is skipped' do
      fx = build_xcode_project(tmpdir)
      out, _err, _status = run_main(e2e_env(fx, 'AC_VERSION_NUMBER_SOURCE' => 'xcode'))
      expect(out).to include('No build number source specified')
    end
  end

  context 'both sources together' do
    it 'updates the build and version numbers in one run' do
      fx = build_xcode_project(tmpdir)
      _out, _err, status = run_main(
        e2e_env(fx,
                'AC_BUILD_NUMBER_SOURCE'   => 'xcode',
                'AC_BUILD_OFFSET'          => '1',
                'AC_VERSION_NUMBER_SOURCE' => 'xcode',
                'AC_VERSION_STRATEGY'      => 'patch',
                'AC_VERSION_OFFSET'        => '1')
      )
      expect(status.exitstatus).to eq(0)
      plist = read_plist(fx.plist_path)
      expect(plist['CFBundleVersion']).to eq('13')
      expect(plist['CFBundleShortVersionString']).to eq('1.2.4')
    end

    it 'exports both output variables' do
      fx = build_xcode_project(tmpdir)
      run_main(
        e2e_env(fx,
                'AC_BUILD_NUMBER_SOURCE'   => 'xcode',
                'AC_BUILD_OFFSET'          => '1',
                'AC_VERSION_NUMBER_SOURCE' => 'xcode')
      )
      env_file = File.read(File.join(fx.root, 'env.sh'))
      expect(env_file).to include('AC_IOS_NEW_BUILD_NUMBER=13')
      expect(env_file).to include('AC_IOS_NEW_VERSION_NUMBER=1.2.3')
    end

    it 'reports success on completion' do
      fx = build_xcode_project(tmpdir)
      out, _err, _status = run_main(
        e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode', 'AC_VERSION_NUMBER_SOURCE' => 'xcode')
      )
      expect(out).to include('has been completed successfully')
    end

    it 'appends to an existing env file rather than truncating it' do
      fx = build_xcode_project(tmpdir)
      env_path = File.join(fx.root, 'env.sh')
      File.write(env_path, "PRE_EXISTING=1\n")
      run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode'))
      expect(File.read(env_path)).to include('PRE_EXISTING=1')
    end
  end

  context 'target selection' do
    it 'updates only the targets named in AC_TARGETS' do
      fx = build_xcode_project(tmpdir, extra_targets: [{ name: 'MyLib', type: :framework }])
      out, _err, status = run_main(
        e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode', 'AC_TARGETS' => 'MyApp')
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Selecting target(s) by name')
      expect(out).to include('Skipping target: MyLib')
    end

    it 'skips non-runnable targets when no filter is given' do
      fx = build_xcode_project(tmpdir, extra_targets: [{ name: 'MyLib', type: :framework }])
      out, _err, _status = run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode'))
      expect(out).to include('Selecting only apps and extensions')
      expect(out).to include('Skipping target: MyLib')
    end
  end

  context 'error branch' do
    it 'aborts with a compatibility message when the project cannot be opened' do
      fx = build_xcode_project(tmpdir)
      FileUtils.rm_rf(fx.proj_path)
      _out, err, status = run_main(e2e_env(fx, 'AC_BUILD_NUMBER_SOURCE' => 'xcode'))
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('not compatible for version upgrade')
    end

    it 'aborts when the resolved configuration does not exist in the project' do
      fx = build_xcode_project(tmpdir)
      _out, err, status = run_main(
        e2e_env(fx,
                'AC_BUILD_NUMBER_SOURCE'    => 'xcode',
                'AC_IOS_CONFIGURATION_NAME' => 'NoSuchConfig')
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).not_to be_empty
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  # Fold in the counts collected from the `ruby main.rb` subprocesses so the
  # guarded top-level block is not reported as dead code.
  child     = subprocess_coverage
  data      = result[main_path].each_with_index.map do |count, idx|
    count.nil? ? nil : count + (child[idx] || 0)
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "  \e[90mMerged from the in-process function tests and the `ruby main.rb`"
  puts "  ENV validation / end-to-end subprocesses.\e[0m"
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(COVERAGE_DIR)
  exit exit_code
end
