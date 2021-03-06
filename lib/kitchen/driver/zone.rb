# -*- encoding: utf-8 -*-
#
# Author:: Scott Hain (<shain@getchef.com>)
#
# Copyright (C) 2015, Scott Hain
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "kitchen"
require "securerandom"
require 'net/ssh'
require_relative "solariszone"

module Kitchen

  module Driver

    # Zone driver for Kitchen.
    #
    # @author Scott Hain <shain@chef.io>
    class Zone < Kitchen::Driver::SSHBase
      default_config :global_zone_hostname, nil
      default_config :global_zone_username, "root"
      default_config :global_zone_password, nil
      default_config :global_zone_port, "22"
      default_config :master_zone_name, "master"
      default_config :master_zone_password, "llama!llama"
      default_config :test_zone_password, "tulips!tulips"
      default_config :private_key,   File.join(Dir.pwd, '.kitchen', 'zone_id_rsa')
      default_config :public_key,    File.join(Dir.pwd, '.kitchen', 'zone_id_rsa.pub')

      def generate_keys
        if !File.exist?(config[:public_key]) || !File.exist?(config[:private_key])
          private_key = OpenSSL::PKey::RSA.new(2048)
          blobbed_key = Base64.encode64(private_key.to_blob).gsub("\n", '')
          public_key = "ssh-rsa #{blobbed_key} kitchen_zone_key"
          File.open(config[:private_key], 'w') do |file|
            file.write(private_key)
            file.chmod(0600)
          end
          File.open(config[:public_key], 'w') do |file|
            file.write(public_key)
            file.chmod(0600)
          end
        end
      end

      # The first time we run, we need to ensure that we have a 'master' template
      # zone to clone. This can cause the first run to be slower.
      def create(state)
        # Set up global zone information
        gz = SolarisZone.new(logger)
        gz.hostname = config[:global_zone_hostname]
        gz.username = config[:global_zone_username]
        gz.password = config[:global_zone_password]

        if gz.verify_connection != 0
          raise Exception, "Could not verify your global zone - verify host, username, and password"
        end

        # Let's see if we're Solaris 10 or 11
        gz.find_version

        generate_keys
        state[:ssh_key] = config[:private_key]
        public_key = IO.read(config[:public_key]).strip

        # Yay! now let's create our new test zone
        tz = SolarisZone.new(logger)
        tz.global_zone = gz
        tz.name = "kitchen-#{SecureRandom.hex(6)}"
        tz.password = config[:test_zone_password]
        tz.ip = config[:test_zone_ip]
        tz.public_key = public_key

        case gz.solaris_version
        when "10"
          # Now that we know our global zone is happy, let's create a master zone!
          mz = SolarisZone.new(logger)
          mz.global_zone = gz
          mz.name = config[:master_zone_name]
          mz.password = config[:master_zone_password]
          mz.ip = config[:master_zone_ip]

          if !mz.exists?
            logger.debug("[kitchen-zone] Zone template #{mz.name} not found - creating now.")
            mz.create
            mz.halt
          else
            logger.debug("[kitchen-zone] Found zone template #{mz.name}")
          end

          if mz.running?
            mz.halt
          end
          tz.clone_from(mz)
        when "11"
          tz.create
        end

        state[:zone_id] = tz.name
        state[:hostname] = tz.ip
        state[:username] = "root"
        state[:password] = tz.password

        tz.sever
        mz.sever unless mz.nil?
        gz.sever

      end

      def destroy(state)
        return if state[:zone_id].nil?

        gz = SolarisZone.new(logger)
        gz.hostname = config[:global_zone_hostname]
        gz.username = config[:global_zone_username]
        gz.password = config[:global_zone_password]

        if gz.verify_connection != 0
          raise Exception, "Could not verify your global zone \
                            - verify hostname, username, and password"
        end

        # Destroy the zone
        tz = SolarisZone.new(logger)
        tz.global_zone = gz
        tz.name = state[:zone_id]
        tz.password = state[:password]
        tz.ip = config[:test_zone_ip]

        tz.destroy
        state.delete(:zone_id)
      end
    end

    class SSHZone < Kitchen::SSH

      def exec(cmd)
        logger.debug("[SSHZone] #{self} (#{cmd})")
        exec_with_return(cmd)
      end

      private

      # Execute a remote command and return the command's exit code.
      #
      # @param cmd [String] command string to execute
      # @return [Hash] contains the exit code, stderr and stdout of the command
      # @api private
      def exec_with_return(cmd)
        return_value = Hash.new
        session.open_channel do |channel|

          channel.request_pty

          channel.exec(cmd) do |_ch, _success|

            channel.on_data do |_ch, data|
              return_value[:stdout] = data.chomp
            end

            channel.on_extended_data do |_ch, _type, data|
              return_value[:stderr] = data.chomp
            end

            channel.on_request("exit-status") do |_ch, data|
              return_value[:exit_code] = data.read_long
            end
          end
        end
        session.loop
        return_value
      end

    end
  end
end
