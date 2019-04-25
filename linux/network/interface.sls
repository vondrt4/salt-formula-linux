{%- from "linux/map.jinja" import network with context %}
{%- from "linux/map.jinja" import system with context %}
{%- if network.enabled %}

{%- macro set_param(param_name, param_dict) -%}
{%- if param_dict.get(param_name, False) -%}
- {{ param_name }}: {{ param_dict[param_name] }}
{%- endif -%}
{%- endmacro -%}

{%- if network.bridge != 'none' %}

linux_network_bridge_pkgs:
  pkg.installed:
  {%- if network.bridge == 'openvswitch' %}
  - pkgs: {{ network.ovs_pkgs }}
  {%- else %}
  - pkgs: {{ network.bridge_pkgs }}
  {%- endif %}

{%- endif %}

{%- for interface_name, interface in network.interface.iteritems() %}

{%- set interface_name = interface.get('name', interface_name) %}

{# it is not used for any interface with type preffix dpdk,eg. dpdk_ovs_port #}
{%- if interface.get('managed', True) and not 'dpdk' in interface.type %}

{%- if grains.os_family in ['RedHat', 'Debian'] %}

{%- if interface.type == 'ovs_bridge' %}

ovs_bridge_{{ interface_name }}:
  openvswitch_bridge.present:
  - name: {{ interface_name }}

{# add linux network interface into OVS bridge #}
{%- for int_name, int in network.interface.iteritems() %}

{%- set int_name = int.get('name', int_name) %}

{%- if int.ovs_bridge is defined and interface_name == int.ovs_bridge %}

add_int_{{ int_name }}_to_ovs_bridge_{{ interface_name }}:
  cmd.run:
    - unless: ovs-vsctl show | grep {{ int_name }}
    - name: ovs-vsctl add-port {{ interface_name }} {{ int_name }}

{%- endif %}

{%- endfor %}

{%- elif interface.type == 'ovs_port' %}

{%- if interface.get('port_type','internal') == 'patch' %}

ovs_port_{{ interface_name }}:
  openvswitch_port.present:
  - name: {{ interface_name }}
  - bridge: {{ interface.bridge }}
  - require:
    - openvswitch_bridge: ovs_bridge_{{ interface.bridge }}

ovs_port_set_type_{{ interface_name }}:
  cmd.run:
  - name: ovs-vsctl set interface {{ interface_name }} type=patch
  - unless: ovs-vsctl show | grep -A 1 'Interface {{ interface_name }}' | grep patch

ovs_port_set_peer_{{ interface_name }}:
  cmd.run:
  - name: ovs-vsctl set interface {{ interface_name }} options:peer={{ interface.peer }}
  - unless: ovs-vsctl show | grep -A 2 'Interface floating-to-prv' | grep {{ interface.peer }}

{%- else %}

linux_interfaces_include_{{ interface_name }}:
  file.prepend:
  - name: /etc/network/interfaces
  - text: |
      source /etc/network/interfaces.d/*
      # Workaround for Upstream-Bug: https://github.com/saltstack/salt/issues/40262
      source /etc/network/interfaces.u/*

ovs_port_{{ interface_name }}:
  file.managed:
  - name: /etc/network/interfaces.u/ifcfg-{{ interface_name }}
  - makedirs: True
  - source: salt://linux/files/ovs_port
  - defaults:
      port: {{ interface|yaml }}
      port_name: {{ interface_name }}
  - template: jinja

ovs_port_{{ interface_name }}_line1:
  file.replace:
  - name: /etc/network/interfaces
  - pattern: auto {{ interface_name }}
  - repl: ""

ovs_port_{{ interface_name }}_line2:
  file.replace:
  - name: /etc/network/interfaces
  - pattern: 'iface {{ interface_name }} inet .*'
  - repl: ""

ovs_port_up_{{ interface_name }}:
  cmd.run:
  - name: ifup {{ interface_name }}
  - require:
    - file: ovs_port_{{ interface_name }}
    - file: ovs_port_{{ interface_name }}_line1
    - file: ovs_port_{{ interface_name }}_line2
    - openvswitch_bridge: ovs_bridge_{{ interface.bridge }}
    - file: linux_interfaces_final_include

{%- endif %}

{%- else %}

linux_interface_{{ interface_name }}:
  network.managed:
  - enabled: {{ interface.enabled }}
  - name: {{ interface_name }}
  - type: {{ interface.type }}
  {%- if interface.address is defined %}
  {%- if grains.os_family == 'Debian' %}
  - proto: {{ interface.get('proto', 'static') }}
  {% endif %}
  {%- if grains.os_family == 'RedHat' %}
  {%- if interface.get('proto', 'none') == 'manual' %}
  - proto: 'none'
  {%- else %}
  - proto: {{ interface.get('proto', 'none') }}
  {%- endif %}
  {% endif %}
  - ipaddr: {{ interface.address }}
  - netmask: {{ interface.netmask }}
  {%- else %}
  - proto: {{ interface.get('proto', 'dhcp') }}
  {%- endif %}
  {%- if interface.type == 'slave' %}
  - master: {{ interface.master }}
  {%- endif %}
  {%- if interface.name_servers is defined %}
  - dns: {{ interface.name_servers }}
  {%- endif %}
  {%- if interface.wireless is defined and grains.os_family == 'Debian' %}
  {%- if interface.wireless.security == "wpa" %}
  - wpa-ssid: {{ interface.wireless.essid }}
  - wpa-psk: {{ interface.wireless.key }}
  {%- else %}
  - wireless-ssid: {{ interface.wireless.essid }}
  - wireless-psk: {{ interface.wireless.key }}
  {%- endif %}
  {%- endif %}
  {%- for param in network.interface_params %}
  {{ set_param(param, interface) }}
  {%- endfor %}
  {%- if interface.type == 'bridge' %}
  - bridge: {{ interface_name }}
  - delay: 0
  - bypassfirewall: True
  - use:
    {%- for network in interface.use_interfaces %}
    - network: linux_interface_{{ network }}
    {%- endfor %}
  - ports: {% for network in interface.get('use_interfaces', []) %}{{ network }} {% endfor %}{% for network in interface.get('use_ovs_ports', []) %}{{ network }} {% endfor %}
  - require:
    {%- for network in interface.get('use_interfaces', []) %}
    - network: linux_interface_{{ network }}
    {%- endfor %}
    {%- for network in interface.get('use_ovs_ports', []) %}
    - cmd: ovs_port_up_{{ network }}
    {%- endfor %}
  {%- endif %}
  {%- if interface.type == 'bond' %}
  - slaves: {{ interface.slaves }}
  - mode: {{ interface.mode }}
  {%- endif %}

{%- for network in interface.get('use_ovs_ports', []) %}

remove_interface_{{ network }}_line1:
  file.replace:
  - name: /etc/network/interfaces
  - pattern: auto {{ network }}
  - repl: ""

remove_interface_{{ network }}_line2:
  file.replace:
  - name: /etc/network/interfaces
  - pattern: iface {{ network }} inet manual
  - repl: ""

{%- endfor %}

{%- if interface.gateway is defined %}

linux_system_network:
  network.system:
  - enabled: {{ interface.enabled }}
  - hostname: {{ network.fqdn }}
  {%- if interface.gateway is defined %}
  - gateway: {{ interface.gateway }}
  - gatewaydev: {{ interface_name }}
  {%- endif %}
  - nozeroconf: True
  - nisdomain: {{ system.domain }}
  - require_reboot: True

{%- endif %}

{%- endif %}

{%- endif %}

{%- if interface.wireless is defined %}

{%- if grains.os_family == 'Arch' %}

linux_network_packages:
  pkg.installed:
  - pkgs: {{ network.pkgs }}

/etc/netctl/network_{{ interface.wireless.essid }}:
  file.managed:
  - source: salt://linux/files/wireless
  - mode: 755
  - template: jinja
  - require:
    - pkg: linux_network_packages
  - defaults:
      interface_name: {{ interface_name }}

switch_profile_{{ interface.wireless.essid }}:
  cmd.run:
    - name: netctl switch-to network_{{ interface.wireless.essid }}
    - cwd: /root
    - unless: "iwconfig {{ interface_name }} | grep -e 'ESSID:\"{{ interface.wireless.essid }}\"'"
    - require:
      - file: /etc/netctl/network_{{ interface.wireless.essid }}

enable_profile_{{ interface.wireless.essid }}:
  cmd.run:
    - name: netctl enable network_{{ interface.wireless.essid }}
    - cwd: /root
    - unless: test -e /etc/systemd/system/multi-user.target.wants/netctl@network_{{ interface.wireless.essid }}.service
    - require:
      - file: /etc/netctl/network_{{ interface.wireless.essid }}

{%- endif %}

{%- endif %}

{%- endif %}

{%- if interface.route is defined %}

linux_network_{{ interface_name }}_routes:
  network.routes:
  - name: {{ interface_name }}
  - routes:
    {%- for route_name, route in interface.route.iteritems() %}
    - name: {{ route_name }}
      ipaddr: {{ route.address }}
      netmask: {{ route.netmask }}
      gateway: {{ route.gateway }}
    {%- endfor %}

{%- endif %}

{%- endfor %}

{%- if network.bridge != 'none' %}

linux_interfaces_final_include:
  file.prepend:
  - name: /etc/network/interfaces
  - text: |
      source /etc/network/interfaces.d/*
      # Workaround for Upstream-Bug: https://github.com/saltstack/salt/issues/40262
      source /etc/network/interfaces.u/*

{%- endif %}

{%- endif %}

{%- if network.network_manager.disable is defined and network.network_manager.disable == True %}

NetworkManager:
  service.dead:
  - enable: false

{%- endif %}

{%- if network.tap_custom_txqueuelen is defined %}

/etc/udev/rules.d/60-net-txqueue.rules:
  file.managed:
  - source: salt://linux/files/60-net-txqueue.rules
  - mode: 755
  - template: jinja

{%- endif %}
