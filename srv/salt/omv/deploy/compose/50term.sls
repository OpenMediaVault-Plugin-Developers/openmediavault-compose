{% set config = salt['omv_conf.get']('conf.service.compose') %}
{% set webadmin = salt['omv_conf.get']('conf.webadmin') %}

{% if config.execenable | to_bool %}

configure_compose_term:
  file.managed:
    - name: "/etc/omv_compose_term.conf"
    - source:
      - salt://{{ tpldir }}/files/etc-omv_compose_term_conf.j2
    - template: jinja
    - context:
        config: {{ config | json }}
        webadmin: {{ webadmin | json }}
    - user: root
    - group: root
    - mode: 644

configure_compose_term_unit:
  file.managed:
    - name: "/etc/systemd/system/omv_compose_term.service"
    - source:
      - salt://{{ tpldir }}/files/unit.j2
    - template: jinja
    - context:
        config: {{ config | json }}
        webadmin: {{ webadmin | json }}
    - user: root
    - group: root
    - mode: 644

systemd_daemon_reload_compose_term:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: configure_compose_term
      - file: configure_compose_term_unit

start_compose_term_service:
  service.running:
    - name: omv_compose_term
    - enable: True
    - watch:
      - file: configure_compose_term
      - file: configure_compose_term_unit

{% else %}

stop_compose_term_service:
  service.dead:
    - name: omv_compose_term
    - enable: False

remove_compose_term_unit:
  file.absent:
    - name: "/etc/systemd/system/omv_compose_term.service"

systemd_daemon_reload_compose_term2:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: remove_compose_term_unit

{% endif %}
