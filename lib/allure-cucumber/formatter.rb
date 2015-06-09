require 'pathname'
require 'uuid'
require 'allure-ruby-adaptor-api'

module AllureCucumber
  class Formatter

    include AllureCucumber::DSL
    
    TEST_HOOK_NAMES_TO_IGNORE = ['Before hook', 'After hook']

    POSSIBLE_STATUSES = ['passed', 'failed', 'pending', 'skipped', 'undefined']
    
    def initialize(step_mother, io, options)
      dir = Pathname.new(AllureCucumber::Config.output_dir)      
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      @tracker = AllureCucumber::FeatureTracker.create
      @deferred_before_test_steps = []
      @deferred_after_test_steps = []
    end
    
    # Start the test suite
    def before_feature(feature)
      feature_identifier = ENV['FEATURE_IDENTIFIER'] && "#{ENV['FEATURE_IDENTIFIER']} - "
      @tracker.feature_name = "#{feature_identifier}#{feature.name.gsub(/\n/, " ")}"
      AllureRubyAdaptorApi::Builder.start_suite(@tracker.feature_name)
    end

    # Find sceanrio type
    def before_feature_element(feature_element)
      @scenario_outline = feature_element.instance_of?(Cucumber::Core::Ast::ScenarioOutline)
    end
    
    def scenario_name(keyword, name, *args)
      scenario_name = (name.nil? || name == "") ? "Unnamed scenario" : name.gsub(/\n/, " ")
      @scenario_outline ? @scenario_outline_name = scenario_name : @tracker.scenario_name = scenario_name 
    end

    def before_examples(*args)
      @header_row = true
      @row_count = 0
    end
    
    # Start the test for normal scenarios
    def before_steps(steps)
      if !@scenario_outline  
        start_test
      end
    end
    
    # Stop the test for normal scenarios
    def after_steps(steps)
      if !@scenario_outline 
        result = test_result(steps)
        stop_test(result)
      end
    end
    
    # Start the test for scenario examples
    def before_table_row(table_row)
      if @scenario_outline && !@header_row && !@in_multiline_arg
        @row_count += 1
        @tracker.scenario_name = "Example #{@row_count} : #{@scenario_outline_name}"
        start_test
      end
    end

    # Stop the test for scenario examples 
    def after_table_row(table_row)
      unless @multiline_arg
        if @scenario_outline && !@header_row 
          result = test_result(table_row)
          stop_test(result)
        end
        @header_row = false
      end
    end
    
    def before_test_step(test_step)
      if !TEST_HOOK_NAMES_TO_IGNORE.include?(test_step.name) 
        if @tracker.scenario_name
          @tracker.step_name = test_step.name
          start_step
        else
          @deferred_before_test_steps << {:step => test_step, :timestamp => Time.now}
        end        
      end
    end
    
    def after_test_step(test_step, result)
      if !TEST_HOOK_NAMES_TO_IGNORE.include?(test_step.name) 
        if @tracker.scenario_name
          status = step_status(result)
          stop_step(status)
        else
          @deferred_after_test_steps << {:step => test_step, :result => result, :timestamp => Time.now}
        end
      end
    end

    # Stop the suite
    def after_feature(feature)
      AllureRubyAdaptorApi::Builder.stop_suite(@tracker.feature_name)
    end

    def after_features(features)
      AllureRubyAdaptorApi::Builder.build!
    end
    
    def before_multiline_arg(multiline_arg)
      @in_multiline_arg = true
      # For background steps defer multiline attachment
      if @tracker.scenario_name.nil?
        @deferred_before_test_steps[-1].merge!({:multiline_arg => multiline_arg})
      else
        attach_multiline_arg_to_file(multiline_arg)
      end
    end

    def after_multiline_arg(multiline_arg)
      @in_multiline_arg = false
    end
    
    private

    def step_status(result)
      POSSIBLE_STATUSES.each do |status|
        return cucumber_status_to_allure_status(status) if result.send("#{status}?")
      end
    end
    
    def test_result(result)
      status = cucumber_status_to_allure_status(result.status)
      exception = status == 'failed' && result.exception.nil? ? Exception.new("Some steps were undefined") : result.exception
      if exception 
        return {:status => status, :exception => exception}
      else
        return {:status => status}
      end
    end
    
    def cucumber_status_to_allure_status(status)
      status.to_s == "undefined" ? "failed" : status.to_s
    end
    
    def attach_multiline_arg_to_file(multiline_arg)
      dir = File.expand_path(AllureCucumber::Config.output_dir)
      out_file = "#{dir}/#{UUID.new.generate}.txt"     
      File.open(out_file, "w+") { |file| file.write(multiline_arg.to_s.gsub(/\e\[(\d+)(;\d+)*m/,'')) }
      attach_file("multiline_arg", File.open(out_file))
    end

    def start_test
      if @tracker.scenario_name
        AllureRubyAdaptorApi::Builder.start_test(@tracker.feature_name, @tracker.scenario_name, :feature => @tracker.feature_name, :story => @tracker.scenario_name)
        post_deferred_steps
      end
    end

    def post_deferred_steps
      @deferred_before_test_steps.size.times do |index|
        @tracker.step_name = @deferred_before_test_steps[index][:step].name 
        start_step
        multiline_arg = @deferred_before_test_steps[index][:multiline_arg]
        attach_multiline_arg_to_file(multiline_arg) if multiline_arg
        if index < @deferred_after_test_steps.size
          result = step_status(@deferred_after_test_steps[index][:result])
          stop_step(result)
        end
      end
    end
    
    def stop_test(result)
      if @deferred_before_test_steps != []
        result[:started_at] = @deferred_before_test_steps[0][:timestamp]
      end
      if @tracker.scenario_name
        AllureRubyAdaptorApi::Builder.stop_test(@tracker.feature_name, @tracker.scenario_name, result)
        @tracker.scenario_name = nil
        @deferred_before_test_steps = []
        @deferred_after_test_steps = []
      end
    end
    
    def start_step(step_name = @tracker.step_name)
      AllureRubyAdaptorApi::Builder.start_step(@tracker.feature_name, @tracker.scenario_name, step_name) 
    end

    def stop_step(status, step_name = @tracker.step_name)
      AllureRubyAdaptorApi::Builder.stop_step(@tracker.feature_name, @tracker.scenario_name, step_name, status) 
    end
    
  end  
end

