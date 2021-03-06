module Puppet
  module Acceptance
    module CronUtils
      def clean(agent, o={})
        o = {:user => 'tstuser'}.merge(o)
        run_cron_on(agent, :remove, o[:user])
        apply_manifest_on(agent, %[user { '%s': ensure => absent, managehome => false }] % o[:user])
      end

      def setup(agent, o={})
        o = {:user => 'tstuser'}.merge(o)
        apply_manifest_on(agent, %[user { '%s': ensure => present, managehome => false }] % o[:user])
        apply_manifest_on(agent, %[case $operatingsystem {
                                     centos, redhat: {$cron = 'cronie'}
                                     solaris: { $cron = 'core-os' }
                                     default: {$cron ='cron'} }
                                     package {'cron': name=> $cron, ensure=>present, }])
      end
    end

    module CAUtils

      def initialize_ssl
        hostname = on(master, 'facter hostname').stdout.strip
        fqdn = on(master, 'facter fqdn').stdout.strip

        step "Clear SSL on all hosts"
        hosts.each do |host|
          ssldir = on(host, puppet('agent --configprint ssldir')).stdout.chomp
          on(host, "rm -rf '#{ssldir}'")
        end

        step "Master: Start Puppet Master" do
          with_puppet_running_on(master, :main => { :dns_alt_names => "puppet,#{hostname},#{fqdn}", :verbose => true, :daemonize => true }) do

            hosts.each do |host|
              next if host['roles'].include? 'master'

              step "Agents: Run agent --test first time to gen CSR"
              on host, puppet("agent --test --server #{master}"), :acceptable_exit_codes => [1]
            end

            # Sign all waiting certs
            step "Master: sign all certs"
            on master, puppet("cert --sign --all"), :acceptable_exit_codes => [0,24]

            step "Agents: Run agent --test second time to obtain signed cert"
            on agents, puppet("agent --test --server #{master}"), :acceptable_exit_codes => [0,2]
          end
        end
      end

      def clean_cert(host, cn, check = true)
        on(host, puppet('cert', 'clean', cn), :acceptable_exit_codes => check ? [0] : [0, 24])
        if check
          assert_match(/remov.*Certificate.*#{cn}/i, stdout, "Should see a log message that certificate request was removed.")
          on(host, puppet('cert', 'list', '--all'))
          assert_no_match(/#{cn}/, stdout, "Should not see certificate in list anymore.")
        end
      end

      def clear_agent_ssl
        return if master.is_pe?
        step "All: Clear agent only ssl settings (do not clear master)"
        hosts.each do |host|
          next if host == master
          ssldir = on(host, puppet('agent --configprint ssldir')).stdout.chomp
          on( host, host_command("rm -rf '#{ssldir}'") )
        end
      end

      def reset_agent_ssl(resign = true)
        return if master.is_pe?
        clear_agent_ssl

        hostname = master.execute('facter hostname')
        fqdn = master.execute('facter fqdn')

        step "Master: Ensure the master bootstraps CA"
        with_puppet_running_on(master,
                                :master => {
                                  :dns_alt_names => "puppet,#{hostname},#{fqdn}",
                                  :autosign => true,
                                }
                              ) do

          agents.each do |agent|
            next if agent == master

            step "Clear old agent certificate from master" do
              agent_cn = on(agent, puppet('agent --configprint certname')).stdout.chomp
              clean_cert(master, agent_cn, false) if agent_cn
            end
            if resign
              step "Agents: Run agent --test once to obtained auto-signed cert" do
                on agent, puppet('agent', "--test --server #{master}"), :acceptable_exit_codes => [0,2]
              end
            end
          end

        end
      end

    end
  end
end
