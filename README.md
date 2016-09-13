# Addon vCloud Driver

![Alt text](picts/one_vcloud.png)

## Description

This addon gives Opennebula the posibility to manage resources in VMware vCloud infraestructures. 
It includes virtualization and monitoring drivers.

This driver is based on [vCenter Driver](https://github.com/OpenNebula/one/blob/master/src/vmm_mad/remotes/vcenter/vcenter_driver.rb) and uses a
modified version of [ruby_vcloud_sdk](https://github.com/vchs/ruby_vcloud_sdk).

![Alt text](picts/diagram.png)

This is the readme for the current development version. 

## Features

This addon has the following capabilities:

* Deploy, stop, shutdown, reboot, save, suspend, resume and delete VM's in the Virtual Data Centers hosted in vCloud.
* Create, delete and revert snapshots of VM's.
* It's able to hot-attach and detach NICs to VM's.
* Automatized customization of the VMs instanciated.
* Obtain monitoring information from the VDC, Datastore and VM's.
* In this development version we manage vApps with one VMs inside (A VM in OpenNebula equals a vApp with one VM in vCloud).
* Each Virtual Data Center (VDC) in vCloud is managed as a Host in OpenNebula.
* Import networks, hosts, templates and datastores hosted in vCloud using onevcloud script.

## Development

To contribute bug patches or new features, you can use the github 
Pull Request model. It is assumed that code and documentation are 
contributed under the Apache License 2.0. 

More info: 

* [How to Contribute] (http://opennebula.org/software:addons#how_to_contribute_to_an_existing_add-on) 
* Support: [OpenNebula user mailing list] (http://opennebula.org/community:mailinglists) 
* Development: [OpenNebula developers mailing list] (http://opennebula.org/community:mailinglists) 
* Issues Tracking: [Github issues] (https://github.com/CSUC/OpenNebula-vCloud-Driver/issues)

## Authors

CSUC - Consorci de Serveis Universitaris de Catalunya

* [http://www.csuc.cat] (http://www.csuc.cat)
* [CSUC GitHub] (https://github.com/CSUC)


## Compatibility

This addon was tested on OpenNebula 5.02, with the 
frontend installed on Ubuntu 14.04.


## Installation, Configuration and Usage

Use [this guide](https://github.com/CSUC/OpenNebula-vCloud-Driver/blob/master/Guide.md)

## References

* [CSUC] (http://www.csuc.cat)
* [OpenNebula] (http://opennebula.org/)

## License

[Apache 2.0] (https://github.com/CSUC/OpenNebula-vCloud-Driver/blob/master/LICENSE)
