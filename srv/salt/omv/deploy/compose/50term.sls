{% set config = salt['omv_conf.get']('conf.service.compose') %}
{% set webadmin = salt['omv_conf.get']('conf.webadmin') %}

{% if config.execenable | to_bool %}

configure_compose_term:
  file.managed:
    - name: "/etc/omv-compose-term.conf"
    - source:
      - salt://{{ tpldir }}/files/etc-omv_compose_term_conf.j2
    - template: jinja
    - context:
        config: {{ config | json }}
        webadmin: {{ webadmin | json }}
    - user: root
    - group: root
    - mode: 644

start_compose_term_service:
  service.running:
    - name: omv-compose-term
    - enable: True
    - watch:
      - file: configure_compose_term

{% else %}

stop_compose_term_service:
  service.dead:
    - name: omv-compose-term
    - enable: False

{% endif %}
