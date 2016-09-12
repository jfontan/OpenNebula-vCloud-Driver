# ---------------------------------------------------------------------------- #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

# -------------------------------------------------------------------------#
# Set up the environment for the driver                                    #
# -------------------------------------------------------------------------#
ONE_LOCATION = ENV["ONE_LOCATION"] if !defined?(ONE_LOCATION)

if !ONE_LOCATION
   BIN_LOCATION = "/usr/bin" if !defined?(BIN_LOCATION)
   LIB_LOCATION = "/usr/lib/one" if !defined?(LIB_LOCATION)
   ETC_LOCATION = "/etc/one/" if !defined?(ETC_LOCATION)
   VAR_LOCATION = "/var/lib/one" if !defined?(VAR_LOCATION)
else
   BIN_LOCATION = ONE_LOCATION + "/bin" if !defined?(BIN_LOCATION)
   LIB_LOCATION = ONE_LOCATION + "/lib" if !defined?(LIB_LOCATION)
   ETC_LOCATION = ONE_LOCATION  + "/etc/" if !defined?(ETC_LOCATION)
   VAR_LOCATION = ONE_LOCATION + "/var/" if !defined?(VAR_LOCATION)
end

ENV['LANG'] = 'C'

$: << LIB_LOCATION+'/ruby'

require 'ruby_vcloud_sdk'
require 'pp'
require 'ostruct'
require 'yaml'
require 'opennebula'
require 'base64'
require 'openssl'
require 'VirtualMachineDriver'

module VCloudDriver

#################################################################################################################
# This class represents a VCloud connection and an associated OpenNebula client
# The connection is associated to the VCloud backing a given OpenNebula host.
# For the VCloud driver each OpenNebula host represents a VCloud vcd
#################################################################################################################

class VCDConnection
	attr_reader :vcd_connection, :user, :pass, :host, :vdc, :vdc_ci, :org, :org_ci, :one, :one_host

    #############################################################################################################
    # Initializr the VCDConnection, and creates an OpenNebula client. The parameters
    # are obtained from the associated OpenNebula host
    # @param hid [Integer] The OpenNebula host id with VCloud attributes
    #############################################################################################################
	def initialize(hid)
    	initialize_one

        @one_host = ::OpenNebula::Host.new_with_id(hid, @one)
        puts @one_host.info
        rc = @one_host.info

        if ::OpenNebula.is_error?(rc)
        	raise "Error getting host information: #{rc.message}"
        end  
          
        password = @one_host["TEMPLATE/VCLOUD_PASSWORD"]
        if !@token.nil?
            begin
                cipher = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
               	cipher.decrypt
                cipher.key = @token
                password =  cipher.update(Base64::decode64(password))
                password << cipher.final
            rescue
                raise "Error decrypting vCloud password"
            end
        end 		
		connection = {
            :host     => @one_host["TEMPLATE/VCLOUD_URI"],
            :user     => @one_host["TEMPLATE/VCLOUD_USER"],
            :password => password,
            :vdc      => @one_host["TEMPLATE/VCLOUD_VDC"],
            :org      => @one_host["TEMPLATE/VCLOUD_USER"].gsub(/^.*\@/, "")
        }

        initialize_vcd(connection)
    end

    #############################################################################################################
    # Initialize a connection with vCloud Director. Options
    # @param options[Hash] with:
    #    :user => The vcloud director user
    #    :password => Password for the user
    #    :host => vCloud Director URI
    #    :vdc => Virtual Data Center
    #    :org => Organization
    #############################################################################################################
    def initialize_vcd(user_opts={})
       
        @user = user_opts[:user]
        @pass = user_opts[:password]
        @host = user_opts[:host]
        @vdc  = user_opts[:vdc]
        @org  = user_opts[:org]

        log_file = "/var/log/one/vcloud.log"
        FileUtils.mkdir_p(File.dirname(log_file))
        @logger = Logger.new(log_file)
        @logger.level = Logger::DEBUG

        begin
            @vcd_connection  = VCloudSdk::Client.new(
                url = "https://#{@host}",
                username = @user,
                password = @pass,
                options = {},
                logger =  @logger,
            )

            @vdc_ci = @vcd_connection.find_vdc_by_name(@vdc)

        rescue Exception => e
            raise "Error connecting to #{@host}: #{e.message}"
        end
    end

    #############################################################################################################
    # Initialize a VCDConnection based just on the VCDConnection parameters. 
    # The OpenNebula client is also initilialized
    #############################################################################################################
    def self.new_connection(user_opts)

        conn = allocate

        conn.initialize_one

        conn.initialize_vcd(user_opts)

        return conn
    end
    
    #############################################################################################################
    # Initialize an OpenNebula connection with the default ONE_AUTH
    #############################################################################################################
    def initialize_one
        begin
            @one   = ::OpenNebula::Client.new()
            system = ::OpenNebula::System.new(@one)

            config = system.get_configuration()

            if ::OpenNebula.is_error?(config)
                raise "Error getting oned configuration : #{config.message}"
            end

            @token = config["ONE_KEY"]
            rescue Exception => e
                raise "Error initializing OpenNebula client: #{e.message}"
        end
    end

    def self.translate_hostname(hostname)        
        host_pool = OpenNebula::HostPool.new(::OpenNebula::Client.new())
        rc        = host_pool.info
        raise "Could not find host #{hostname}" if OpenNebula.is_error?(rc)

        host = host_pool.select {|host_element| host_element.name==hostname }              
        return host.first.id
    end

    #############################################################################################################
    # Obtains the name of the datastore identified by ds_id.
    #  @param   ds_id [String] The ONE identifier for the datastore.
    #  @return        [String] The name of the datastore.
    #############################################################################################################
    def self.find_ds_name(ds_id)
        ds = OpenNebula::Datastore.new_with_id(ds_id)
        rc = ds.info
        raise "Could not find datastore #{ds_id}" if OpenNebula.is_error?(rc)

        return ds.name
    end

    #############################################################################################################
    # Obtains the VM associated to vApp identified by uuid.
    #  @param    uuid [String] The identifier for the vApp.
    #  @return        [VCloudSdk::Vm] The Vm object.
    #############################################################################################################
    def find_vm_template(uuid)
        vapp = @vdc_ci.find_vapp_by_id(uuid)
        return vapp.vms.first if !vapp.vms.nil?
    end

    #############################################################################################################
    # Obtains the vApp identified by uuid.
    #  @param    uuid [String] The identifier for the vApp.
    #  @return        [VCloudSdk::Vapp] The Vapp object.
    #############################################################################################################
    def find_vapp(uuid)  
        return @vdc_ci.find_vapp_by_id(uuid)        
    end

    def encrypt_password(pass)
        cipher = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
        cipher.encrypt
        cipher.key = @token
        password = cipher.update(pass)
        password << cipher.final
        password_64 = Base64.encode64(password).chop
    end

    ######################### Datastore Operations ##############################################################

    #############################################################################################################
    # Create a VirtualDisk
    # @return name of the final image
    #############################################################################################################
    def create_virtual_disk(img_name, ds_name, size, adapter_type, disk_type)
        #NOT IMPLEMENTED YET
        return true
    end

    #############################################################################################################
    # Delete a VirtualDisk
    # @param img_name [String] name of the image
    # @param ds_name  [String] name of the datastore where the VD resides
    #############################################################################################################
    def delete_virtual_disk(img_name, ds_name)
        #NOT IMPLEMENTED YET
        return true              
    end

    #############################################################################################################
    # Returns Datastore information
    # @param    ds_name [String] name of the datastore
    # @return           [String] monitor information of the DS
    #############################################################################################################
    def monitor_ds(ds_name)
        # Find datastore within datacenter
        ds = vdc_ci.find_storage_profile_by_name(ds_name)            
        
        total_mb    = ds.storage_limit_mb.to_i
        free_mb     = ds.available_storage.to_i
        used_mb     = ds.storage_used_mb.to_i

        "USED_MB=#{used_mb}\nFREE_MB=#{free_mb} \nTOTAL_MB=#{total_mb}"
    end
end

class VCloudHost < ::OpenNebula::Host

    UNLIMITED = 9999999

	attr_reader :vcd_client, :vcd_connection
	
    def initialize(client)
       	@vcd_client = client
        @vdc        = client.vdc_ci   	
    end

    #############################################################################################################
    # Generate an OpenNebula monitor string for this host. 
    #  More info: http://docs.opennebula.org/4.14/integration/infrastructure_integration/devel-im.html
    #  HYPERVISOR   => Name of the hypervisor of the host 
    #  CPU_SPEED    => Speed in Mhz of the CPUs.
    #  TOTAL_CPU    =>  Number of CPUs multiplied by 100.
    #  USEDCPU      =>  Percentage of used CPU multiplied by the number of cores.
    #  FREECPU      =>  Percentage of idling CPU multiplied by the number of cores.
    #  
    #  TOTALMEMORY  =>  Maximum memory that could be used for VMs.
    #  FREEMEMORY   =>  Available memory for VMs at that moment, in kilobytes.
    #  USEDMEMORY   =>  Memory used, in kilobytes.
    #############################################################################################################
    def monitor_cluster

       	#Load the host systems          
        summary  =	@vdc.resources
     
		str_info = ""
		# System
		str_info << "HYPERVISOR=vcloud\n"
		
		# CPU
		mhz_core = vcd_client.one_host["TEMPLATE/CPUSPEED"].to_i
		str_info << "CPUSPEED=" << mhz_core.to_s  << "\n"
        
        cpu   = vcd_client.one_host["TEMPLATE/CPU"]

        if !cpu.nil? and cpu == "UNLIMITED"
            cpu = UNLIMITED
        else
            cpu = summary.cpu_limit.to_i
        end

		str_info << "TOTALCPU=" << (cpu / mhz_core * 100).to_s << "\n"
		str_info << "USEDCPU="  << (summary.cpu_used.to_i / mhz_core * 100).to_s << "\n"
		str_info << "FREECPU="  << (summary.cpu_available.to_i / mhz_core * 100).to_s << "\n"

		# Memory
        memory   = vcd_client.one_host["TEMPLATE/MEMORY"]

        if !memory.nil? and memory == "UNLIMITED"
            memory = UNLIMITED
        else
            memory = summary.memory_limit.to_i
        end

		str_info << "TOTALMEMORY=" << (memory * 1024).to_s << "\n"
		str_info << "FREEMEMORY="  << (summary.memory_available.to_i * 1024).to_s << "\n"
		str_info << "USEDMEMORY="  << (summary.memory_used.to_i * 1024).to_s
	end

    #############################################################################################################
    # Generate an OpenNebula monitor string for the VMs in this host. 
    #  More info: http://docs.opennebula.org/4.14/integration/infrastructure_integration/devel-im.html
    #  ID           => Name of the hypervisor of the host 
    #  DEPLOY_ID    =>  The vCloud identifier of the vAPP
    #  VM_NAME      =>  The vCloud name of the vApp.
    #  POLL         =>  The information of the vApp (STATE,USED_CPU,USED_MEMORY,IPs,OS,VMTOOLS_VERSION)
    #############################################################################################################
    def monitor_vms

        str_info = ""

        begin
            @vdc.vapps.each { |vapp|            
                name = vapp.name                                
                number = -1
                # Extract vmid if possible
                matches = name.match(/^one-(\d*)(-(.*))?$/)
                number  = matches[1] if matches
                vapp.vms.each { |v|
                    vm = VCloudVm.new(@vcd_connection,v)                    
                    vm.monitor
                    str_info << "\nVM = ["                
                    str_info << "ID=#{number},"
                    str_info << "DEPLOY_ID=\"#{vapp.id}\","
                    str_info << "VM_NAME=\"#{vapp.name.gsub(/^.*-/, "")}\","
                    str_info << "POLL=\"#{vm.info}\"]"           
                
                }
            }
        rescue Exception => e
            STDERR.puts e.inspect
            STDERR.puts e.backtrace
        end
        return str_info
    end

    #############################################################################################################
    #  Creates an OpenNebula host representing a Virtual Data Center in this 
    #  VCloud
    #  @param vdc    [VCloudSdk::VDC] the VDC oject representing Virtual Data Center
    #  @param client [VCDConnection] to create the host
    #  @return In case of success [0, host_id] or [-1, error_msg]
    #############################################################################################################
    def self.to_one(vdc, client)
        one_host = ::OpenNebula::Host.new(::OpenNebula::Host.build_xml,
            client.one)
  
        rc = one_host.allocate(vdc.name.to_s, 'vcloud', 'vcloud',
                ::OpenNebula::ClusterPool::NONE_CLUSTER_ID)
        
        return -1, rc.message if ::OpenNebula.is_error?(rc)

        password = client.encrypt_password(client.pass)

        template =  "HYPERVISOR=\"vcloud\"\n"
        template =  "PUBLIC_CLOUD=\"YES\"\n"
        template =  "CPUSPEED=\"1500\"\n"                  
        template << "VCLOUD_URI=\"#{client.host}\"\n"
        template << "VCLOUD_PASSWORD=\"#{password}\"\n"
        template << "VCLOUD_VDC=\"#{vdc.name}\"\n"
        template << "VCLOUD_USER=\"#{client.user}\"\n"
        template << "CPU=\"UNLIMITED\"\n" if vdc.resources.cpu_limit.to_i == 0
        template << "MEMORY=\"UNLIMITED\"\n" if vdc.resources.memory_limit.to_i == 0

        rc = one_host.update(template, false)

        if ::OpenNebula.is_error?(rc)
            error = rc.message

            rc = one_host.delete

            if ::OpenNebula.is_error?(rc)
                error << ". Host #{vdc.name} could not be"\
                    " deleted: #{rc.message}."
            end

            return -1, error
        end

        return 0, one_host.id
    end
end

class VCloudVm
    attr_reader :vm

    POLL_ATTRIBUTE  = VirtualMachineDriver::POLL_ATTRIBUTE
    VM_STATE        = VirtualMachineDriver::VM_STATE

    #############################################################################################################
    #  Creates a new VIVm using a RbVmomi::VirtualMachine object
    #    @param client [VCenterClient] client to connect to vCenter
    #    @param vm_vi [RbVmomi::VirtualMachine] it will be used if not nil
    #############################################################################################################
    def initialize(client, vm_vi )
        @vm     = vm_vi
        @client = client

        @used_cpu    = 0
        @used_memory = 0

        @netrx = 0
        @nettx = 0
    end

    #############################################################################################################
    #  Initialize the vm monitor information
    #############################################################################################################
    def monitor  
        @state   = state_to_c(@vm.status)

        if @state != VM_STATE[:active]

            @used_cpu    = 0
            @used_memory = 0
            @netrx       = 0
            @nettx       = 0
            return
        end

        @used_memory     = @vm.memory
        @used_cpu        = @vm.vcpu

        # Check for negative values
        @used_memory     = 0 if @used_memory.to_i < 0
        @used_cpu        = 0 if @used_cpu.to_i < 0

                
        @guest_ip_addresses        = @vm.ip_address if !@vm.ip_address.nil?

        @guest_ip                  = @guest_ip.first  if @guest_ip 
        @guest_ip_addresses        = @guest_ip_addresses.join(',') if !@vm.ip_address.nil?
        
        @os                        = @vm.operating_system.delete(' ')
        @vmtools_ver               = @vm.vmtools_version          

    end

    #############################################################################################################
    #  Generates a OpenNebula IM Driver valid string with the monitor info for this VM.
    #   More info: http://docs.opennebula.org/4.14/integration/infrastructure_integration/devel-vmm.html
    #   GUEST_IP        => The IP or IPs assigned to this VM.
    #   STATE           => The state of the VM.
    #   USED_CPU        => The amount of CPU used.
    #   USED_MEMORY     => The amount of CPU used.
    #   NETRX           => NOT AVAILABLE (0)
    #   NETTX           => NOT AVAILABLE (0)
    #   OS              => The OS installed on the VM.
    #   VMTOOLS_VERSION => The vmtools version installed on the VM
    #############################################################################################################
    def info
      return 'STATE=d' if @state == 'd'

      str_info = ""

      str_info << "GUEST_IP=" << @guest_ip.to_s << " " if !@guest_ip.nil?       
      if @guest_ip_addresses && !@guest_ip_addresses.empty?
          str_info << "GUEST_IP_ADDRESSES=\\\"" <<
              @guest_ip_addresses.to_s << "\\\" "
      end    
      str_info << "#{POLL_ATTRIBUTE[:state]}="  << @state                << " "
      str_info << "#{POLL_ATTRIBUTE[:cpu]}="    << @used_cpu.to_s        << " "
      str_info << "#{POLL_ATTRIBUTE[:memory]}=" << @used_memory.to_s     << " "
      str_info << "#{POLL_ATTRIBUTE[:netrx]}="  << @netrx.to_s           << " "
      str_info << "#{POLL_ATTRIBUTE[:nettx]}="  << @nettx.to_s           << " "
      str_info << "OPERATING_SYSTEM="           << @os.to_s              << " " 
      str_info << "VMWARETOOLS_VERSION="        << @vmtools_ver.to_s     << " "
    end

    #############################################################################################################
    # Deploys a vApp
    #  @param xml_text  [String] XML representation of the vApp
    #  @param lcm_state [String] 
    #  @param deploy_id [String]
    #  @param hostname  [String]
    #############################################################################################################
    def self.deploy(xml_text, lcm_state, deploy_id, hostname)
        if lcm_state == "BOOT" || lcm_state == "BOOT_FAILURE"                      
            return clone_vm(xml_text, hostname)
        else                              
            hid         = VCDConnection::translate_hostname(hostname) 
            connection  = VCDConnection.new(hid)
            vapp        = connection.find_vapp(deploy_id)       
            xml         = REXML::Document.new xml_text
                        
            reconfigure_vm(vapp, xml, false, hostname)

            vapp.power_on
            return vapp.id                  
        end
    end

    #############################################################################################################
    # Cancels a VM
    #  @param deploy_id vcloud identifier of the VM
    #  @param hostname name of the host (equals the vCloud VDC)
    #  @param lcm_state state of the VM
    #  @param keep_disks keep or not VM disks in datastore
    #  @param disks VM attached disks
    #############################################################################################################   
    def self.cancel(deploy_id, hostname, lcm_state, keep_disks)        
        case lcm_state
            when "SHUTDOWN","SHUTDOWN_POWEROFF", "SHUTDOWN_UNDEPLOY"
                shutdown(deploy_id, hostname, lcm_state, keep_disks)
            when "CANCEL", "LCM_INIT", "CLEANUP_RESUBMIT", "SHUTDOWN", "CLEANUP_DELETE"
                hid         = VCDConnection::translate_hostname(hostname) 
                connection  = VCDConnection.new(hid)
                vapp        = connection.find_vapp(deploy_id) 

                begin                    
                    if vapp.status == "POWERED_ON"                                                
                        vapp.power_off
                    end
                rescue
                end

                ips = vapp.vms.first.ip_address           

                connection.vdc_ci.edge_gateways.first.remove_fw_rules(ips) if !ips.nil?

                vapp.delete
            else 
                raise "LCM_STATE #{lcm_state} not supported for cancel"
        end

    end

    #############################################################################################################
    # Reboots a vApp
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.reboot(deploy_id, hostname)
        hid         = VCDConnection::translate_hostname(hostname) 
        connection  = VCDConnection.new(hid)  
        vapp        = connection.find_vapp(deploy_id)

        vapp.reboot
    end

    #############################################################################################################
    # Resets a vApp
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.reset(deploy_id, hostname)
        hid         = VCDConnection::translate_hostname(hostname) 
        connection  = VCDConnection.new(hid)  
        vapp        = connection.find_vapp(deploy_id)

        vapp.reset
    end

    #############################################################################################################
    # Resumes a vApp
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.resume(deploy_id, hostname)   
        hid         = VCDConnection::translate_hostname(hostname) 
        connection  = VCDConnection.new(hid)  
        vapp        = connection.find_vapp(deploy_id)

        vapp.power_on
    end

    #############################################################################################################
    # Saves a vApp
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.save(deploy_id, hostname, lcm_state)
        case lcm_state
            when "SAVE_MIGRATE"
                raise "Migration between vCloud cluster not supported"
            when "SAVE_SUSPEND", "SAVE_STOP"
                hid         = VCDConnection::translate_hostname(hostname) 
                connection  = VCDConnection.new(hid)  
                vapp        = connection.find_vapp(deploy_id)
                    
                vapp.suspend
        end
    end

    #############################################################################################################
    # Shutdown a vApp
    #  @param deploy_id vCloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.shutdown(deploy_id, hostname, lcm_state, keep_disks)

        hid         = VCDConnection::translate_hostname(hostname) 
        connection  = VCDConnection.new(hid)

        vapp        = connection.find_vapp(deploy_id) 

        case lcm_state
            when "SHUTDOWN"   
                ips = vapp.vms.first.ip_address

                vapp.shutdown if vapp.vms.first.vmtools_version != "9227"                                             
                vapp.power_off                

                connection.vdc_ci.edge_gateways.first.remove_fw_rules(ips) if !ips.nil?

                vapp.delete                                
                
            when "SHUTDOWN_POWEROFF", "SHUTDOWN_UNDEPLOY"                
                vapp.shutdown if vapp.vms.first.vmtools_version != "9227"                         
                vapp.power_off
        end
    end   

    #############################################################################################################
    # Create vApp snapshot
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #  @param snaphot_name name of the snapshot
    #############################################################################################################
    def self.create_snapshot(deploy_id, hostname, snapshot_name)
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)

        snapshot_hash = {
            :name => snapshot_name,
            :description => "OpenNebula Snapshot of vApp #{deploy_id}",
        }

        vapp.create_snapshot(snapshot_hash)

        return snapshot_name
    end

    #############################################################################################################
    # Delete ALL vApp snapshots
    #  @param deploy_id     vcloud identifier of the vApp
    #  @param hostname      name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.delete_snapshot(deploy_id, hostname)
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)

        vapp.remove_snapshot
    end

    #############################################################################################################
    # Revert the LAST vApp snapshot
    #  @param deploy_id vcloud identifier of the vApp
    #  @param hostname name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.revert_snapshot(deploy_id, hostname)        
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)
        
        vapp.revert_snapshot
    end

    #############################################################################################################
    # Attach NIC to a VM
    #  If VMware tools are installed, we can attach NIC in a powered on VM.
    #  @param deploy_id     vCloud identifier of the VM
    #  @param mac           Optional.MAC address of the NIC to be attached
    #  @param bridge        The name of the Network in vCloud
    #  @param hostname      Name of the host (equals the vCloud VDC)
    #############################################################################################################
    def self.attach_nic(deploy_id, mac, bridge, hostname)        
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)
        vm          = vapp.vms.first

        #Add network "bridge" to vApp                                                    
        vapp.add_network_by_name(bridge) if !vapp.list_networks.include? "#{bridge}"        
        
        #Attach NIC in mode "POOL" to VM connected to network "bridged"
        vm.add_nic(bridge,"POOL",mac)
    end

    #############################################################################################################
    # Detach NIC from a VM.
    #  To detach NICs the VM must be POWERED OFF.
    #############################################################################################################
    def self.detach_nic(deploy_id, mac, hostname)        
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)

        vm          = vapp.vms.first
        nic         = vm.find_nic_by_mac(mac)

        if nic
            if vm.status == "POWERED_ON"
                if vm.vmtools_version != "9227"
                    vm.shutdown 
                else
                    vm.power_off
                end
                vm.delete_nics(nic)
                vm.power_on
            else
                vm.delete_nics(nic)
            end
        end
    end

    #############################################################################################################
    # Reconfigures a VM (context data)
    #  @param deploy_id vcloud identifier of the VM
    #  @param hostname name of the host (equals the vCloud VDC)
    #  @param xml_text XML repsentation of the VM
    #############################################################################################################
    def self.reconfigure(deploy_id, hostname, xml_text)
        return true
        hid         = VCDConnection::translate_hostname(hostname)
        connection  = VCDConnection.new(hid)
        vapp        = connection.find_vapp(deploy_id)

        xml         = REXML::Document.new xml_text
        context     = xml.root.elements["//TEMPLATE/CONTEXT"]

        if context
            options_vm = hash_spec_vm(context)
            vapp.vms.first.reconfigure(options_vm)
        end
    end

    #############################################################################################################
    # Converts a vCloud vApp template object to a ONE template.
    #  @param template     [VCloudSdk::Catalog_Item] The template object.
    #  @param catalog_name [String] The name of the template's catalog.
    #  @return             [String] The ONE template data.
    #############################################################################################################
    def self.to_one(template,catalog_name)
        
        operating_system = "UNKNOWN"
        operating_system = "LINUX" if template.name.downcase.include? "linux"
        operating_system = "WINDOWS" if template.name.downcase.include? "windows"

        str =   "NAME   = \"#{template.name} - #{catalog_name}\"\n"                         
        str <<  "CPU    = \"1\"\n"                                         
        str <<  "MEMORY = \"1024\"\n"                          
        str <<  "HYPERVISOR = \"vcloud\"\n"                     
        str <<  "SCHED_REQUIREMENTS=\"HYPERVISOR=\\\"vcloud\\\"\"\n"
        str <<  "CONTEXT = [\n"
        str <<  "  CUSTOMIZE = \"YES\",\n" 
        str <<  "  HOSTNAME = \"cloud-$UNAME\",\n"                            
        str <<  "  USERNAME = \"$UNAME\",\n"        
        str <<  "  PASSWORD = \"$USER[PASS_WIN]\",\n" if operating_system ==  "WINDOWS"        
        str <<  "  PASSWORD = \"$USER[PASS]\",\n" if operating_system ==  "LINUX"
        str <<  "  ROOT_PASS = \"$USER[ROOT_PASS]\",\n"                                  
        str <<  "  NETWORK = \"YES\",\n"   
        str <<  "  SSH_PUBLIC_KEY = \"$USER[SSH_PUBLIC_KEY]\",\n" if operating_system ==  "LINUX"      
        str <<  "  OS = \"#{operating_system}\",\n"
        str <<  "  WHITE_TCP_PORTS = \"22,80\"\n"  
        str <<  "]\n"                  
        str <<  "PUBLIC_CLOUD = [\n"
        str <<  "  TYPE        =\"vcloud\",\n"
        str <<  "  VM_TEMPLATE =\"#{template.id}\",\n"
        str <<  "  VM_TEMPLATE_NAME =\"#{template.name}\",\n"
        str <<  "  CATALOG_NAME =\"#{catalog_name}\"\n"                        
        str <<  "]\n"

        if template.description.empty?
            str << "DESCRIPTION = \"vCloud Template imported by OpenNebula"\
                                   " from catalog #{catalog_name}\"\n"
        else                            
            str << "DESCRIPTION = \"#{template.description}"\
                                " - vCloud Template imported by OpenNebula\"\n"
        end       
    end

    private
         
    #############################################################################################################
    #  Clone a vCloud vApp Template and leaves it powered on
    #############################################################################################################
    def self.clone_vm(xml_text, hostname)

        xml = REXML::Document.new xml_text        
        pcs = xml.root.get_elements("//USER_TEMPLATE/PUBLIC_CLOUD")

        raise "Cannot find VCloud element in VM template." if pcs.nil?

        template = pcs.select { |t|
            type = t.elements["TYPE"]
            !type.nil? && type.text.downcase == "vcloud"
        }

        raise "Cannot find vCloud element in VM template." if template.nil?

        template_id         = template[0].elements["VM_TEMPLATE"]
        catalog_name        = template[0].elements["CATALOG_NAME"].text
        

        raise "Cannot find VM_TEMPLATE in vCloud element." if template_id.nil?

        template_id         = template_id.text
        vmid                =  xml.root.elements["/VM/ID"].text
        vApp_name           = "one-#{vmid}-#{xml.root.elements["/VM/NAME"].text}"
        hid                 = xml.root.elements["//HISTORY_RECORDS/HISTORY/HID"].text
        user                = xml.root.elements["/VM/UNAME"].text
        ports               = xml.root.elements["/VM/TEMPLATE/CONTEXT/WHITE_TCP_PORTS"].text.split(',')
            
        raise "Cannot find host id in deployment file history." if hid.nil?

        begin
            connection          = VCDConnection.new(hid)         
            catalog             = connection.vcd_connection.find_catalog_by_name(catalog_name)
            template            = catalog.find_vapp_template_by_id(template_id)
            vdc_name            = connection.vdc
            vApp_description    = "vApp instantiated by OpenNebula by user #{user} " 

            vapp                = catalog.instantiate_vapp_template(template.name,
                                                                vdc_name,vApp_name,vApp_description)
            vm                  = vapp.vms.first   
       
        rescue Exception => e
            raise "Cannot clone vApp Template #{e.message}"
        end

        reconfigure_vm(vapp, xml, true, hostname)
        vapp                = connection.vdc_ci.find_vapp_by_name(vApp_name)
        vapp.power_on
        vm = vapp.vms.first
   
        ##FW SECTION 
        if !vm.ip_address.nil? and !ports.nil?
            configure_firewall(connection,vApp_name,vm.ip_address,ports) 
        end
        return vapp.id
    end

    #############################################################################################################
    # Converts the VM's xml especification to a hash.
    #  @param   xml [XML]   The ONE especification for the VM.
    #  @return      [Hash]  The Hash especification for the VM.
    #############################################################################################################
    def self.hash_spec_vm(xml)

        id            = xml.root.elements["/VM/ID"].text
        name          = xml.root.elements["/VM/NAME"].text
        vm_name       = "vm-one-#{id}-#{name}"
        cpu           = xml.root.elements["/VM/TEMPLATE/CPU"] ? xml.root.elements["/VM/TEMPLATE/CPU"].text : 1
        memory        = xml.root.elements["/VM/TEMPLATE/MEMORY"].text
        description   = "VM of one-#{id}-#{name}"    

        #NETWORK SECTION
        array_nics    = []   
        nics          = xml.root.get_elements("/VM/TEMPLATE/NIC")        
        
        if !nics.nil?
            nics.each { |nic|
                nic_opt = {
                        :network_name =>  nic.elements["NETWORK"].text,
                        :mac          =>  nic.elements["MAC"].text
                }
                array_nics.push(nic_opt)
            }
        end       

        #HASH CREATION
        hash_spec = {
            :name => vm_name,
            :description => description,
            :vcpu => cpu,
            :memory => memory,
            :nics => array_nics,
            :vapp_name => "one-#{id}-#{name}"            
        }
        return hash_spec          
    end 

    #############################################################################################################
    # Reconfigures a vApp with new deployment description
    #############################################################################################################
    def self.reconfigure_vm(vapp, xml, newvm, hostname)
        vm = vapp.vms.first

        if !newvm
            #SNAPSHOT SECTION (we have to remove the snapshots before reconfigure the vm)
            vapp.remove_snapshot if vapp.snapshot_info 
        end

        if newvm 
            #CUSTOMIZATION SECTION
            customize       = xml.root.elements["/VM/TEMPLATE/CONTEXT/CUSTOMIZE"].text

            if customize == "YES"
                hostname        = xml.root.elements["/VM/TEMPLATE/CONTEXT/HOSTNAME"].text
                root_pass       = xml.root.elements["/VM/TEMPLATE/CONTEXT/ROOT_PASS"].text
                context         = xml.root.elements["/VM/TEMPLATE/CONTEXT"]                

                script          = xml.root.elements["/VM/TEMPLATE/CONTEXT/START_SCRIPT"].text
  
                opts            = {
                                :computer_name => hostname,
                                :admin_pass => root_pass,
                                :custom_script => script 
                                }

                vm.customization(opts)
            end                
        end

        #RECONFIGURE SECTION        
        options_vm = hash_spec_vm(xml)
        vm.reconfigure(options_vm)                
    end

    #############################################################################################################
    # Attach disk to a VM
    # @params hostname[String] vcenter cluster name in opennebula as host
    # @params deploy_id[String] deploy id of the vm
    # @params ds_name[String] name of the datastore
    # @params img_name[String] path of the image
    # @params size_kb[String] size in kb of the disk
    # @params vm[RbVmomi::VIM::VirtualMachine] VM if called from instance
    # @params connection[ViClient::conneciton] connection if called from instance
    #############################################################################################################
    def self.attach_disk(hostname, deploy_id, ds_name,img_name, size_mb, vapp=nil, connection=nil)
        #NOT IMPLEMENTED YET
        return true    
    end

    #############################################################################################################
    # Detach a specific disk from a VM
    # Attach disk to a VM
    # @params hostname  [String] vcenter cluster name in opennebula as host
    # @params deploy_id [String] deploy id of the vm
    # @params ds_name   [String] name of the datastore
    # @params img_path  [String] path of the image
    #############################################################################################################
    def self.detach_disk(hostname, deploy_id, ds_name, img_path)
        #NOT IMPLEMENTED YET
        return true
    end

    #############################################################################################################
    # Detach all disks from a VM
    # @params vm[VCenterVm] vCenter VM
    #############################################################################################################
    def self.detach_all_disks(vm)
        #NOT IMPLEMENTED YET
        return true
    end

    #############################################################################################################
    # Detach attached disks from a VM
    #############################################################################################################
    def self.detach_attached_disks(vm, disks, hostname)
        #NOT IMPLEMENTED YET
        return true
    end
    
    #############################################################################################################
    # Obtains the customization script for the Virtual Machine
    #  @params context [XML] The ONE template's context
    #  @return         [String] The customization script
    #############################################################################################################
    def self.custom_script(context)

         user_pubkey = context.elements["SSH_PUBLIC_KEY"].text if !context.elements["SSH_PUBLIC_KEY"].nil? 
         username    = context.elements["USERNAME"].text
         password    = context.elements["PASSWORD"].text  if !context.elements["PASSWORD"].nil? 
         os          = context.elements["OS"].text.downcase

        if os == "linux"
            script = "#!/bin/sh\n"
            script << "if [ $1 == 'precustomization' ]; then\n"
            script << "  echo \"Do Nothing\"\n"
            script << "elif [ $1 == 'postcustomization' ]; then\n"
            if !password.nil?
                script << "  useradd -p \'#{password}\' -s /bin/bash -m #{username}\n"
            else
                script << "  useradd -s /bin/bash -m #{username}\n"  
            end
            if !user_pubkey.nil?
                script << "  mkdir -p /home/#{username}/.ssh\n"
                script << "  chown #{username}:#{username} /home/#{username}/.ssh\n"
                script << "  chmod 700 /home/#{username}/.ssh\n"
                script << "  echo #{user_pubkey} > /home/#{username}/.ssh/authorized_keys\n"
                script << "  chown #{username}:#{username} /home/#{username}/.ssh/authorized_keys\n"
                script << "  chmod 644 /home/#{username}/.ssh/authorized_keys\n"
            end
            script << "  echo \"#{username} ALL=(ALL:ALL) NOPASSWD: ALL\" >> /etc/sudoers\n"
            script << "fi"

        elsif os == "windows"

            script = "@echo off\n"
            script << "if \"%1%\" == \"precustomization\" (\n"
            script << "  echo \"Do precustomization tasks\"\n"
            script << ") else if \"%1%\" == \"postcustomization\" (\n"
            script << "  echo \"Do postcustomization tasks\"\n"           
            script << "  net user Administrator Abc123.\n"

            if !password.nil?
                script << "  net user #{username} #{password} /add\n"
                script << "  net localgroup administrators #{username} /add\n"
            end 

            script << ")\n"       
        else
            nil
        end
    end
    
    #############################################################################################################
    # Converts the vCloud string state to OpenNebula state convention
    #  @param state [String] The states could be "POWERED ON", "SUSPENDED"
    #                        "POWERED_OFF"
    #  @ return [String] 
    # Guest states are:
    # - -1           The vApp is currently FAILED_CREATION.
    # - 0           The vApp is currently UNRESOLVED.
    # - 1           The vApp is currently RESOLVED.
    # - 3           The vApp is currently SUSPENDED.
    # - 4           The vApp is currently POWERED_ON.
    # - 5           The vApp is currently WAITING_FOR_INPUT.    
    # - 6          The vApp is currently UNKNOWN.
    # - 7          The vApp is currently UNRECOGNIZED.
    # - 8          The vApp is currently POWERED_OFF.
    # - other        The vApp is in other state.
    #############################################################################################################
    def state_to_c(state)
     
        case state
            when 'POWERED_ON'
                VM_STATE[:active]
            when 'SUSPENDED'
                VM_STATE[:suspended]
            when 'POWERED_OFF'
                VM_STATE[:deleted]
            else
                VM_STATE[:unknown]
        end
    end    

end
#################################################################################################################
end