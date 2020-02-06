#
# Copyright 2015-2017, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'shellwords'

require 'chef/mixin/which'
require 'chef/provider/package'
require 'chef/resource/package'
require 'poise'

require 'poise_python/python_command_mixin'


module PoisePython
  module Resources
    # (see PythonPackage::Resource)
    # @since 1.0.0
    module PythonPackage
      # A `python_package` resource to manage Python installations using pip.
      #
      # @provides python_package
      # @action install
      # @action upgrade
      # @action uninstall
      # @example
      #   python_package 'django' do
      #     python '2'
      #     version '1.8.3'
      #   end
      class Resource < Chef::Resource::Package
        include PoisePython::PythonCommandMixin
        provides(:python_package)
        # Manually create matchers because #actions is unreliable.
        %i{install upgrade remove}.each do |action|
          Poise::Helpers::ChefspecMatchers.create_matcher(:python_package, action)
        end

        # @!attribute group
        #   System group to install the package.
        #   @return [String, Integer, nil]
        attribute(:group, kind_of: [String, Integer, NilClass], default: lazy { default_group })
        # @!attribute install_options
        #   Options string to be used with `pip install`.
        #   @return [String, Array<String>, nil, false]
        attribute(:install_options, kind_of: [String, Array, NilClass, FalseClass], default: nil)
        # @!attribute list_options
        #   Options string to be used with `pip list`.
        #   @return [String, Array<String>, nil, false]
        attribute(:list_options, kind_of: [String, Array, NilClass, FalseClass], default: nil)
        # @!attribute user
        #   System user to install the package.
        #   @return [String, Integer, nil]
        attribute(:user, kind_of: [String, Integer, NilClass], default: lazy { default_user })

        # This should probably be in the base class but ¯\_(ツ)_/¯.
        # @!attribute allow_downgrade
        #   Allow downgrading the package.
        #   @return [Boolean]
        attribute(:allow_downgrade, kind_of: [TrueClass, FalseClass], default: false)

        def initialize(*args)
          super
          # For older Chef.
          @resource_name = :python_package
          # We don't have these actions.
          @allowed_actions.delete(:purge)
          @allowed_actions.delete(:reconfig)
        end

        # Upstream attribute we don't support. Sets are an error and gets always
        # return nil.
        #
        # @api private
        # @param arg [Object] Ignored
        # @return [nil]
        def response_file(arg=nil)
          raise NoMethodError if arg
        end

        # (see #response_file)
        def response_file_variables(arg=nil)
          raise NoMethodError if arg && arg != {}
        end

        # (see #response_file)
        def source(arg=nil)
          raise NoMethodError if arg
        end

        private

        # Find a default group, if any, from the parent Python.
        #
        # @api private
        # @return [String, Integer, nil]
        def default_group
          # Use an explicit is_a? hack because python_runtime is a container so
          # it gets the whole DSL and this will always respond_to?(:group).
          if parent_python && parent_python.is_a?(PoisePython::Resources::PythonVirtualenv::Resource)
            parent_python.group
          else
            nil
          end
        end

        # Find a default user, if any, from the parent Python.
        #
        # @api private
        # @return [String, Integer, nil]
        def default_user
          # See default_group for explanation of is_a? hack grossness.
          if parent_python && parent_python.is_a?(PoisePython::Resources::PythonVirtualenv::Resource)
            parent_python.user
          else
            nil
          end
        end
      end

      # The default provider for the `python_package` resource.
      #
      # @see Resource
      class Provider < Chef::Provider::Package
        include PoisePython::PythonCommandMixin
        provides(:python_package)

        # Load current and candidate versions for all needed packages.
        #
        # @api private
        # @return [Chef::Resource]
        def load_current_resource
          @current_resource = new_resource.class.new(new_resource.name, run_context)
          current_resource.package_name(new_resource.package_name)
          check_package_versions(current_resource)
          Chef::Log.debug("[#{new_resource}] Current version: #{current_resource.version}, candidate version: #{@candidate_version}")
          current_resource
        end

        # Populate current and candidate versions for all needed packages.
        #
        # @api private
        # @param resource [PoisePython::Resources::PythonPackage::Resource]
        #   Resource to load for.
        # @param version [String, Array<String>] Current version(s) of package(s).
        # @return [void]
        def check_package_versions(resource, version=new_resource.version)
          version_data = Hash.new {|hash, key| hash[key] = {current: nil, candidate: nil} }
          # Get the version for everything currently installed.
          list = pip_command('list', :list, [], environment: {'PIP_FORMAT' => 'json'}).stdout
          parse_pip_list(list).each do |name, current|
            # Merge current versions in to the data.
            version_data[name][:current] = current
          end
          # Check for newer candidates.
          outdated = pip_outdated(pip_requirements(resource.package_name, version, parse: true))
          outdated.each do |name, candidate|
            # Merge candidates in to the existing versions.
            version_data[name][:candidate] = candidate
          end
          # Populate the current resource and candidate versions. Youch this is
          # a gross mix of data flow.
          if(resource.package_name.is_a?(Array))
            @candidate_version = []
            versions = []
            [resource.package_name].flatten.each do |name|
              ver = version_data[parse_package_name(name)]
              versions << ver[:current]
              @candidate_version << ver[:candidate]
            end
            resource.version(versions)
          else
            ver = version_data[parse_package_name(resource.package_name)]
            resource.version(ver[:current])
            @candidate_version = ver[:candidate]
          end
        end

        # Install package(s) using pip.
        #
        # @param name [String, Array<String>] Name(s) of package(s).
        # @param version [String, Array<String>] Version(s) of package(s).
        # @return [void]
        def install_package(name, version)
          pip_install(name, version, upgrade: false)
        end

        # Upgrade package(s) using pip.
        #
        # @param name [String, Array<String>] Name(s) of package(s).
        # @param version [String, Array<String>] Version(s) of package(s).
        # @return [void]
        def upgrade_package(name, version)
          pip_install(name, version, upgrade: true)
        end

        # Uninstall package(s) using pip.
        #
        # @param name [String, Array<String>] Name(s) of package(s).
        # @param version [String, Array<String>] Version(s) of package(s).
        # @return [void]
        def remove_package(name, version)
          pip_command('uninstall', :install, %w{--yes} + [name].flatten)
        end

        private

        # Convert name(s) and version(s) to an array of pkg_resources.Requirement
        # compatible strings. These are strings like "django" or "django==1.0".
        #
        # @param name [String, Array<String>] Name or names for the packages.
        # @param version [String, Array<String>] Version or versions for the
        #   packages.
        # @param parse [Boolean] Use parsed package names.
        # @return [Array<String>]
        def pip_requirements(name, version, parse: false)
          [name].flatten.zip([version].flatten).map do |n, v|
            n = parse_package_name(n) if parse
            v = v.to_s.strip
            if n =~ /:\/\//
              # Probably a URI.
              n
            elsif v.empty?
              # No version requirement, send through unmodified.
              n
            elsif v =~ /^\d/
              "#{n}==#{v}"
            else
              # If the first character isn't a digit, assume something fancy.
              n + v
            end
          end
        end

        # Run a pip command.
        #
        # @param pip_command [String, nil] The pip subcommand to run (eg. install).
        # @param options_type [Symbol] Either `:install` to `:list` to select
        #   which extra options to use.
        # @param pip_options [Array<String>] Options for the pip command.
        # @param opts [Hash] Mixlib::ShellOut options.
        # @return [Mixlib::ShellOut]
        def pip_command(pip_command, options_type, pip_options=[], opts={})
          runner = opts.delete(:pip_runner) || %w{-m pip.__main__}
          type_specific_options = new_resource.send(:"#{options_type}_options")
          full_cmd = if new_resource.options || type_specific_options
            if (new_resource.options && new_resource.options.is_a?(String)) || (type_specific_options && type_specific_options.is_a?(String))
              # We have to use a string for this case to be safe because the
              # options are a string and I don't want to try and parse that.
              global_options = new_resource.options.is_a?(Array) ? Shellwords.join(new_resource.options) : new_resource.options.to_s
              type_specific_options = type_specific_options.is_a?(Array) ? Shellwords.join(type_specific_options) : type_specific_options.to_s
              "#{runner.join(' ')} #{pip_command} #{global_options} #{type_specific_options} #{Shellwords.join(pip_options)}"
            else
              runner + (pip_command ? [pip_command] : []) + (new_resource.options || []) + (type_specific_options || []) + pip_options
            end
          else
            # No special options, use an array to skip the extra /bin/sh.
            runner + (pip_command ? [pip_command] : []) + pip_options
          end
          # Set user and group.
          opts[:user] = new_resource.user if new_resource.user
          opts[:group] = new_resource.group if new_resource.group

          python_shell_out!(full_cmd, opts)
        end

        # Run `pip install` to install a package(s).
        #
        # @param name [String, Array<String>] Name(s) of package(s) to install.
        # @param version [String, Array<String>] Version(s) of package(s) to
        #   install.
        # @param upgrade [Boolean] Use upgrade mode?
        # @return [Mixlib::ShellOut]
        def pip_install(name, version, upgrade: false)
          cmd = pip_requirements(name, version)
          # Prepend --upgrade if needed.
          cmd = %w{--upgrade} + cmd if upgrade
          pip_command('install', :install, cmd)
        end

        # Run `pip list --outdated` with Shareaholic-specific logic.
        #
        # @see #pip_requirements
        # @param requirements [Array<String>] Pip-formatted package requirements.
        # @return [Hash<String, String>] package -> version
        def pip_outdated(requirements)
          # Normally `pip list --outdated` will list the latest version, and it can be hard to tell
          # whether that means a dependency is actually outdated. eg if foo==3.0 is available but
          # you pin it to foo<3, `pip list --outdated` will still list foo=3.0 as the latest.
          # But at Shareaholic, our requirements.txt is always pinned to the specific version
          # instead of using range or is unranged. So we just need to compare our input
          # requirements vs what the command returns.
          cmd = pip_command('list', :list, %w{--outdated})
          # output format looks like
          # Package    Version Latest Type
          # ---------- ------- ------ -----
          # pip        19.2.3  20.0.2 wheel

          # Convert to req -> requested version
          outdated = cmd.stdout.each_line.drop(2).map do |line|
            line = line.split(/ +/)
            [line[0], line[2]]
          end.to_h

          result = requirements.map do |r|
            r, v = r.split('==')
            [r, outdated[r] || v || '']
          end.to_h

          result
        end

        # Parse the output from `pip list`. Returns a hash of package key to
        # current version.
        #
        # @param text [String] Output to parse.
        # @return [Hash<String, String>]
        def parse_pip_list(text)
          if text[0] == '['
            # Pip 9 or newer, so it understood $PIP_FORMAT=json.
            Chef::JSONCompat.parse(text).each_with_object({}) do |data, memo|
              memo[parse_package_name(data['name'])] = data['version']
            end
          else
            # Pip 8 or earlier, which doesn't support JSON output.
            text.split(/\r?\n/).each_with_object({}) do |line, memo|
              # Example of a line:
              # boto (2.25.0)
              if md = line.match(/^(\S+)\s+\(([^\s,]+).*\)$/i)
                memo[parse_package_name(md[1])] = md[2]
              else
                Chef::Log.debug("[#{new_resource}] Unparsable line in pip list: #{line}")
              end
            end
          end
        end

        # Regexp for package URLs.
        PACKAGE_NAME_URL = /:\/\/.*?#egg=(.*)$/

        # Regexp for extras.
        PACKAGE_NAME_EXTRA = /^(.*?)\[.*?\]$/

        # Find the underlying name from a pip input sequence.
        #
        # @param raw_name [String] Raw package name.
        # @return [String]
        def parse_package_name(raw_name)
          case raw_name
          when PACKAGE_NAME_URL, PACKAGE_NAME_EXTRA
            $1
          else
            raw_name
          end.downcase.gsub(/_/, '-')
        end

      end
    end
  end
end
